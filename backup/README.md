Отличный выбор. **Velero** — это стандарт де-факто для бэкапов в Kubernetes.

Учитывая, что у вас **NFS-хранилище** (managed-nfs-storage), мы не можем использовать "нативные снапшоты дисков" (как в AWS EBS или Google Disk). Нам нужно использовать **File System Backup** (ранее известный как Restic, теперь Kopia/Restic). Это значит, что Velero будет "залезать" внутрь подов и копировать файлы с примонтированных томов байт-в-байт в MinIO.

### План внедрения Velero

1.  **Подготовка MinIO:** Создание бакета и пользователя.
2.  **Конфигурация Helm:** Настройка `values.yaml` для работы с MinIO и NFS.
3.  **Установка:** Развертывание в кластер.
4.  **Установка CLI:** Утилита управления на мастер-ноде.
5.  **Тест-драйв:** Бэкап и восстановление тестового приложения.

---

### Шаг 1. Подготовка MinIO

Вам нужно создать отдельный бакет для бэкапов.
Зайдите в консоль MinIO (`https://minio.ccsfarm.local`) и выполните:
1.  Создайте Bucket: **`velero-backups`**.
2.  (Опционально) Создайте пользователя `velero` с правами `readwrite` (или используйте существующие ключи `loki`/`admin`).
    *   *В примере ниже я буду использовать ключи `loki` (`FeerDe3o`), так как они у нас уже есть в истории, но лучше создать отдельного юзера.*

---

### Шаг 2. Создание `velero-values.yaml`

Создайте файл `velero-values.yaml`. Я адаптировал его под вашу инфраструктуру: включил **Node Agent** (для NFS) и настроил S3.

```yaml
# velero-values.yaml

# 1. Настройки плагинов
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.9.0
    volumeMounts:
      - mountPath: /target
        name: plugins

# 2. Общая конфигурация
configuration:
  # Провайдер AWS используется для любого S3 (в т.ч. MinIO)
  provider: aws
  
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-backups
      config:
        region: us-east-1
        s3ForcePathStyle: "true" # Критично для MinIO
        s3Url: http://minio.minio.svc.cluster.local:9000 # Внутренний адрес (быстрее)
        publicUrl: https://minio.ccsfarm.local # Для скачивания логов через CLI извне

  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: us-east-1

# 3. Учетные данные (Credentials)
credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id = loki
      aws_secret_access_key = FeerDe3o

# 4. Настройка агентов для NFS (File System Backup)
deployNodeAgent: true

# Глобальная настройка: если PV не поддерживает снапшоты (наш случай с NFS),
# использовать копирование файлов (FS Backup) по умолчанию.
defaultVolumesToFsBackup: true

# 5. Ресурсы (опционально, но полезно)
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1024Mi

# 6. Расписание (Пример)
schedules:
  daily-full:
    disabled: false
    schedule: "0 3 * * *" # В 3:00 ночи
    template:
      ttl: "720h" # Хранить 30 дней
      includedNamespaces:
        - "*" # Бэкапить все неймспейсы
      snapshotVolumes: true
```

---

### Шаг 3. Установка Velero в кластер

1.  Добавьте репозиторий VMware Tanzu (разработчики Velero):
    ```bash
    helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
    helm repo update
    ```

2.  Установите чарт:
    ```bash
    helm upgrade --install velero vmware-tanzu/velero \
      --namespace velero --create-namespace \
      -f velero-values.yaml
    ```

3.  Проверьте, что поды запустились:
    ```bash
    kubectl get pods -n velero
    ```
    *Вы должны увидеть один под `velero-server` и по одному поду `velero-node-agent` на каждую Worker-ноду (DaemonSet).*

---

### Шаг 4. Установка Velero CLI (Клиент)

Управлять бэкапами удобнее через консольную утилиту. Установим её на `k8s-master`.

```bash
# Скачиваем последнюю версию (проверьте актуальность на GitHub, сейчас v1.13+)
wget https://github.com/vmware-tanzu/velero/releases/download/v1.17.1/velero-v1.17.1-linux-amd64.tar.gz

# Распаковываем
tar -zxvf velero-v1.17.1-linux-amd64.tar.gz

# Перемещаем бинарник в PATH
sudo mv velero-v1.17.1-linux-amd64/velero /usr/local/bin/

# Чистим мусор
rm -rf velero-v1.17.1-linux-amd64*

# Проверяем
velero version
```

---

### Шаг 5. Тестирование (Backup & Restore)

Самый важный этап. Проверим, работает ли бэкап данных с NFS.

**1. Создадим тестовое приложение с данными:**
Создайте файл `nginx-test.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: velero-test
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nginx-logs
  namespace: velero-test
spec:
  storageClassName: managed-nfs-storage
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: velero-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        volumeMounts:
        - mountPath: /var/log/nginx
          name: logs
      volumes:
      - name: logs
        persistentVolumeClaim:
          claimName: nginx-logs
```

Примените его:
```bash
kubectl apply -f nginx-test.yaml
```

**2. Запишем данные:**
```bash
# Ждем запуска
kubectl wait --for=condition=ready pod -l app=nginx -n velero-test

# Пишем файл в PVC
kubectl exec -n velero-test $(kubectl get pod -n velero-test -l app=nginx -o name) -- sh -c "echo 'Hello Velero from NFS!' > /var/log/nginx/important-data.txt"
```

**3. Создаем бэкап:**
```bash
# Запускаем бэкап неймспейса
velero backup create test-backup --include-namespaces velero-test --wait
```
*Команда вернет управление, когда бэкап завершится. Если долго висит — проверьте логи: `kubectl logs -n velero -l name=velero`.*

**4. Удаляем неймспейс (Симуляция аварии):**
```bash
kubectl delete namespace velero-test
```
*Убедитесь, что namespace исчез.*

**5. Восстанавливаем:**
```bash
velero restore create --from-backup test-backup --wait
```

**6. Проверяем данные:**
```bash
kubectl get pods -n velero-test
# Проверяем содержимое файла
kubectl exec -n velero-test $(kubectl get pod -n velero-test -l app=nginx -o name) -- cat /var/log/nginx/important-data.txt
```

Если вы увидите `Hello Velero from NFS!` — поздравляю! Ваша система Disaster Recovery настроена и работает с NFS хранилищем.