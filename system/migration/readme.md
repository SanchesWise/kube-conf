Это логичный и правильный шаг для повышения производительности (особенно для БД) и отказоустойчивости.

**Внимание по ресурсам:**
У тебя 4 диска по 100 ГБ.
*   Total Raw Capacity: 400 GB.
*   При репликации **x2** полезное пространство: **200 GB**.
*   Nexus (если он полный) может занять всё место.
*   **Совет:** Убедись, что в Longhorn включен **Over-provisioning** (по умолчанию 200%), и следи за реальным заполнением.

---

### Общая стратегия миграции (The Swap Method)

Поскольку Kubernetes не позволяет изменить `storageClassName` у существующего PVC "на лету", алгоритм для всех сервисов (StatefulSet и Deployment) будет одинаковым:

1.  **Stop:** Скейлим приложение в 0.
2.  **Rename:** Переименовываем старый PVC (например, `data-postgres` -> `data-postgres-old`).
3.  **Create:** Создаем новый PVC с тем же именем (`data-postgres`), но с `storageClassName: longhorn`.
4.  **Copy:** Запускаем временный под, который монтирует оба диска (старый и новый) и копирует данные через `rsync`.
5.  **Start:** Скейлим приложение обратно в 1.

Я подготовил для тебя **Универсальный Под-Мигратор**.

---

### 0. Подготовка: Манифест Мигратора

Сохрани этот файл как `migration-job.yaml`. Мы будем менять в нем имена PVC для каждого сервиса.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: migration-helper
  namespace: prod # МЕНЯЙ NAMESPACE ПРИ НЕОБХОДИМОСТИ
spec:
  restartPolicy: Never
  # Важно: запускаем от рута, чтобы rsync сохранил владельцев файлов (chown)
  securityContext:
    runAsUser: 0
    fsGroup: 0
  containers:
  - name: migration
    image: alpine:latest
    command: ["/bin/sh", "-c"]
    args:
      - apk add --no-cache rsync &&
        echo "Starting migration..." &&
        # Флаг -a (archive) сохраняет права, таймстампы и владельцев
        # Флаг -v (verbose) показывает прогресс
        # Флаг --delete удаляет в целевом лишнее (для чистоты)
        rsync -av --progress /source/ /dest/ &&
        echo "Migration finished!" &&
        ls -la /dest
    volumeMounts:
    - name: source-old
      mountPath: /source
    - name: dest-new
      mountPath: /dest
  volumes:
  - name: source-old
    persistentVolumeClaim:
      claimName: DATA-OLD-PVC-NAME # <--- СЮДА ВПИШЕМ ИМЯ СТАРОГО PVC
  - name: dest-new
    persistentVolumeClaim:
      claimName: DATA-NEW-PVC-NAME # <--- СЮДА ВПИШЕМ ИМЯ НОВОГО PVC
```

---

### 1. Миграция PostgreSQL

Это самый критичный сервис. Работаем в неймспейсе `postgres`.

1.  **Остановка:**
    ```bash
    kubectl scale statefulset postgres --replicas=0 -n postgres
    ```

2.  **Работа с PVC:**
    Найди имя текущего PVC: `kubectl get pvc -n postgres`. Обычно это `postgresdata-postgres-0`.

    Мы не можем "переименовать" PVC в K8s. Но мы можем переименовать связь.
    *Хитрость:* StatefulSet ищет PVC строго по имени. Мы "украдем" имя.

    **План "клон":**
    Поскольку это NFS, мы можем просто создать новый PVC Longhorn и скопировать.

    *   **Переименуй существующий PVC объект** (это сложно, проще удалить StatefulSet без удаления подов, но мы пойдем путем создания нового PVC с другим именем и правки StatefulSet, ЛИБО путем подмены PVC).

    **Лучший путь (Подмена PVC):**
    1. Получи yaml старого PVC: `kubectl get pvc postgresdata-postgres-0 -n postgres -o yaml > old-pvc.yaml`.
    2. Измени в файле `name` на `postgresdata-postgres-0-old` и убери `uid`, `resourceVersion`.
    3. Создай "копию определения" (но это будет новый клейм к тому же PV, если NFS поддерживает Retain, иначе сложно).

    **ДАВАЙ ПРОЩЕ (раз у нас NFS):**
    Просто создай **НОВЫЙ** PVC с именем `postgres-longhorn`.

    ```yaml
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: postgres-longhorn
      namespace: postgres
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: longhorn
      resources:
        requests:
          storage: 10Gi
    ```
    `kubectl apply -f ...`

3.  **Копирование:**
    В `migration-job.yaml`:
    *   `claimName: DATA-OLD-PVC-NAME` -> `postgresdata-postgres-0`
    *   `claimName: DATA-NEW-PVC-NAME` -> `postgres-longhorn`
    *   Запусти: `kubectl apply -f migration-job.yaml`
    *   Жди завершения (`kubectl logs -f migration-helper`).
    *   Удали под: `kubectl delete pod migration-helper`.

4.  **Переключение:**
    Отредактируй StatefulSet: `kubectl edit sts postgres -n postgres`.
    *   В разделе `volumeClaimTemplates` измени `storageClassName` на `longhorn`.
    *   **ВНИМАНИЕ:** K8s часто запрещает менять `volumeClaimTemplates` на лету.
    *   **Если запрещает:**
        1. Удали StatefulSet (НО ОСТАВЬ ПОДЫ/PVC!): `kubectl delete sts postgres --cascade=orphan -n postgres`.
        2. Удали старый под: `kubectl delete pod postgres-0 -n postgres`.
        3. Удали старый PVC: `kubectl delete pvc postgresdata-postgres-0 -n postgres`.
        4. **Переименуй** новый PVC `postgres-longhorn` в `postgresdata-postgres-0`:
           (Это нужно сделать через клонирование YAML нового PVC, удаление старого и создание нового с именем старого).

    *Это сложно.* **Давай сделаем путь для ленивых (через дамп), раз у нас настроен бэкап:**
    1. Убедись, что бэкап в MinIO есть (ты делал это вчера).
    2. Удали `helm uninstall` или `kubectl delete -f ...` всего постгреса (включая PVC).
    3. Поменяй в манифестах `storageClassName` на `longhorn`.
    4. Задеплой заново (чистая база).
    5. Восстанови из бэкапа:
       `kubectl exec -i postgres-0 -- psql -U sanches < backup.sql` (скачав его предварительно)
       ИЛИ запусти джобу восстановления (обратную бэкапу).

    **Рекомендую путь через бэкап/восстановление для Postgres**, это чище всего.

---

### 2. Redis

Redis (если он используется как кэш) проще пересоздать.
1.  Поменяй в `values.yaml` (если Helm) или манифесте `storageClassName` на `longhorn`.
2.  Сделай `helm upgrade` или `kubectl apply`.
3.  Он пересоздаст PVC. Данные пропадут (кэш прогреется заново).
4.  Если данные важны (очереди) — используй метод миграции через `rsync` (как ниже для мониторинга).

---

### 3. Мониторинг (Prometheus, Grafana, Loki)

Здесь данных много, они мелкие, терять жалко.
Обычно этот стек стоит через **kube-prometheus-stack**.

**Strategy:**
1.  Измени `values.yaml` чарта:
    ```yaml
    prometheus:
      prometheusSpec:
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: longhorn
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 50Gi

    grafana:
      persistence:
        enabled: true
        storageClassName: longhorn
        size: 10Gi
    ```
    *То же самое для Alertmanager.*

2.  **Loki:**
    Loki обычно хранит чанки в S3 (MinIO), а на диске только WAL и индекс (Compactor).
    В `values.yaml` для Loki:
    ```yaml
    loki:
      commonConfig:
        replication_factor: 1
      singleBinary:
        persistence:
          enabled: true
          storageClass: longhorn
          size: 20Gi
    ```

3.  **Применение (Опасно!):**
    Helm может ругаться, что нельзя менять PVC.
    **Лучший способ:**
    1.  Удали релиз мониторинга: `helm uninstall monitoring -n monitoring`.
    2.  Удали PVC руками: `kubectl delete pvc -n monitoring --all`.
    3.  Поставь заново с новыми values.
    4.  *История метрик пропадет.*

    **Если история критична:**
    Тебе нужно перед удалением PVC создать временный PVC на Longhorn, скопировать туда данные из старых PVC прометеуса/графаны, а потом при установке Helm указать `existingClaim` (если чарт поддерживает) или подменить PVC.
    *Честно? Для пет-проекта проще убить историю мониторинга и начать с чистого листа на быстрых дисках.*

---

### 4. Nexus (Гибридная схема)

Здесь самое интересное. Ты хочешь:
*   Базу Nexus (конфиги, юзеры) — на быстрый Longhorn.
*   Блобы (сами докер-образы, тяжелые файлы) — на NFS (потому что их много и скорость не так важна, как объем).

**Как это сделать:**

Nexus хранит всё в `/nexus-data`. Внутри есть папки `db`, `etc`, `blobs`.

1.  **Создай 2 PVC:**
    *   `nexus-data-lh` (Longhorn, 10Gb) — для корня.
    *   `nexus-blobs-nfs` (NFS, 300Gb) — только для блобов.

2.  **Обнови Deployment Nexus:**
    Смонтируй оба тома. NFS монтируем внутрь папки Longhorn.

```yaml
      containers:
      - name: nexus
        volumeMounts:
        - name: nexus-root
          mountPath: /nexus-data
        - name: nexus-blobs
          mountPath: /nexus-data/blobs/default # Стандартный путь blobstore
      volumes:
      - name: nexus-root
        persistentVolumeClaim:
          claimName: nexus-data-lh
      - name: nexus-blobs
        persistentVolumeClaim:
          claimName: nexus-blobs-nfs # Твой старый PVC или новый на NFS
```

3.  **Миграция данных:**
    Тебе нужно перенести содержимое старого NFS тома на новый LH том, **КРОМЕ** папки `blobs`.

    Используй `migration-job.yaml`:
    *   Монтируй старый NFS в `/source`.
    *   Монтируй новый LH в `/dest`.
    *   Команда:
        ```bash
        # Копируем всё КРОМЕ блобов
        rsync -av --progress --exclude 'blobs' /source/ /dest/
        ```
    *   Папку `blobs` на старом NFS оставь как есть, она станет `nexus-blobs-nfs`.

### Итоговый план действий

1.  **Postgres:** Бэкап в S3 -> Переустановка чарта/манифеста на Longhorn -> Restore из S3. (Самый надежный способ).
2.  **Redis:** Просто переключи SC на Longhorn (кэш сбросится).
3.  **Monitoring:** Переустанови стек на Longhorn (метрики сбросятся, но конфиги графаны лучше экспортировать/сохранить, если они не в Git).
4.  **Nexus:**
    *   Останови Nexus.
    *   Создай том Longhorn.
    *   Скопируй данные (без блобов) с NFS на Longhorn.
    *   На устройстве NFS оставь только папку `blobs` (перемести содержимое корня в архив на всякий случай).
    *   Запусти Nexus с двойным маунтом (Корень=LH, Blobs=NFS).

Это даст тебе **скорость** там, где она нужна (БД, UI Nexus), и **объем** там, где он нужен (Артефакты).