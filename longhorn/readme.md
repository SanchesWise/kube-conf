Да, диск `sdb` (1.7 ТБ) — это **идеальный кандидат**. Использовать отдельный физический диск под данные (Longhorn) намного лучше, чем откусывать место от системного диска (`sda`), так как это разделяет нагрузку ввода-вывода (IOPS).

Однако, судя по выводу `lsblk`, на диске `sdb` **уже есть разделы** (`sdb1` на 500G и `sdb2` на 1.3T).

Прежде чем мы их используем, нужно понять: **нужны ли тебе данные на этих разделах?**

---

### Вариант 1: Данные на `sdb` не нужны (Форматируем под Proxmox) — **Рекомендуемый**

Если этот диск можно очистить, мы создадим на нем **LVM-Thin** хранилище Proxmox. Это даст максимальную скорость и гибкость для виртуальных дисков.

**Инструкция:**

1.  **Проверка (на всякий случай):**
    В консоли Proxmox (где ты делал `lsblk`) введи:
    ```bash
    blkid /dev/sdb1
    blkid /dev/sdb2
    ```
    Если там пусто или написано что-то старое/ненужное — идем дальше.

2.  **Очистка диска (через GUI):**
    *   Зайди в веб-интерфейс Proxmox.
    *   Выбери свою ноду (`chia04`) -> **Disks**.
    *   Найди в списке `/dev/sdb`.
    *   Выбери его и нажми **Wipe Disk** (Осторожно, это удалит все данные с `sdb`!).

3.  **Создание хранилища (LVM-Thin):**
    *   Там же (Нода -> Disks) выбери пункт **LVM-Thin**.
    *   Нажми **Create: Thinpool**.
    *   **Disk:** Выбери `/dev/sdb`.
    *   **Name:** Назови его, например, `ssd-storage` (или `longhorn-data`).
    *   Нажми **Create**.

4.  **Раздача дисков виртуалкам:**
    Теперь, когда хранилище создано, возвращаемся к добавлению дисков для воркеров (`k8s-worker01`...`04`).
    *   VM -> Hardware -> Add -> Hard Disk.
    *   **Storage:** Выбирай созданное хранилище (`ssd-storage`).
    *   **Size:** 50 GiB.
    *   **SSD emulation:** Включено.
    *   **Discard:** Включено.

---

### Вариант 2: Данные на `sdb` нужны (или ты не хочешь форматировать)

Если на `sdb1` или `sdb2` лежат важные данные (например, плоты Chia или бэкапы), форматировать диск нельзя.

В этом случае нужно понять, какая там файловая система, смонтировать её в Proxmox как папку ("Directory") и хранить диски виртуалок в виде файлов `.qcow2`.

1.  Посмотри файловую систему:
    ```bash
    lsblk -f /dev/sdb
    ```
2.  Если там, например, `ext4` или `xfs`, их нужно примонтировать к Proxmox (через `/etc/fstab`) и добавить в **Datacenter -> Storage -> Add -> Directory**.

**Но я настоятельно рекомендую Вариант 1**, если диск можно очистить. Блочный доступ (LVM) для баз данных и Longhorn работает быстрее и надежнее, чем файлы `.qcow2` поверх файловой системы.

**Какой вариант выбираем?** (Если диск можно тереть — делай Вариант 1 смело).


Вот готовый скрипт, который делает всё «под ключ» на каждой ноде:
1.  Устанавливает нужные пакеты (iSCSI, NFS).
2.  Включает сервис `iscsid`.
3.  Форматирует `/dev/sdb` (если он еще не отформатирован).
4.  Создает папку.
5.  Добавляет запись в `/etc/fstab` (через UUID, чтобы не слетело).
6.  Монтирует диск.

### Скрипт: `setup_longhorn_disk.sh`

Создай этот файл на мастере, а потом скопируй на воркеры, или просто копипасти содержимое в терминал каждого воркера.

```bash
#!/bin/bash

# Остановка при любой ошибке
set -e

# --- КОНФИГУРАЦИЯ ---
DISK="/dev/sdb"
MOUNT_POINT="/mnt/longhorn-storage"
# --------------------

echo "=== STARTING SETUP FOR $DISK ==="

# 1. Установка зависимостей (для RED OS / RHEL)
echo "[1/6] Installing dependencies (iscsi, nfs)..."
if command -v dnf &> /dev/null; then
    dnf install -y iscsi-initiator-utils util-linux jq nfs-utils
elif command -v yum &> /dev/null; then
    yum install -y iscsi-initiator-utils util-linux jq nfs-utils
fi

# 2. Включение iscsid (Критично для Longhorn)
echo "[2/6] Enabling iscsid service..."
systemctl enable --now iscsid

# 3. Проверка диска и форматирование
if [ ! -b "$DISK" ]; then
    echo "ERROR: Disk $DISK not found!"
    exit 1
fi

# Проверяем, есть ли уже файловая система
if blkid "$DISK" | grep -q "TYPE"; then
    echo "[3/6] Disk $DISK already formatted. Skipping format."
else
    echo "[3/6] Formatting $DISK to ext4..."
    mkfs.ext4 -F "$DISK"
fi

# 4. Создание точки монтирования
echo "[4/6] Creating directory $MOUNT_POINT..."
mkdir -p "$MOUNT_POINT"

# 5. Настройка fstab
UUID=$(blkid -s UUID -o value "$DISK")
if [ -z "$UUID" ]; then
    echo "ERROR: Could not get UUID for $DISK"
    exit 1
fi

if grep -q "$UUID" /etc/fstab; then
    echo "[5/6] Entry for UUID=$UUID already exists in fstab."
else
    echo "[5/6] Adding $DISK (UUID=$UUID) to /etc/fstab..."
    echo "UUID=$UUID  $MOUNT_POINT  ext4  defaults,noatime  0 0" >> /etc/fstab
fi

# 6. Монтирование
echo "[6/6] Mounting..."
systemctl daemon-reload
mount -a

# Проверка
echo ""
echo "=== SUCCESS! RESULT: ==="
df -h | grep "$MOUNT_POINT"
echo "iscsid status: $(systemctl is-active iscsid)"
```

### Как запустить одной командой на воркере

Если ты зашел по SSH на воркер (например, `k8s-worker01`), просто выполни этот блок (копируй и вставляй целиком):

```bash
cat << 'EOF' > setup_disk.sh
#!/bin/bash
set -e
DISK="/dev/sdb"
MOUNT_POINT="/mnt/longhorn-storage"
echo "Installing dependencies..."
dnf install -y iscsi-initiator-utils util-linux jq nfs-utils
systemctl enable --now iscsid
if ! blkid "$DISK" | grep -q "TYPE"; then
    echo "Formatting $DISK..."
    mkfs.ext4 -F "$DISK"
fi
mkdir -p "$MOUNT_POINT"
UUID=$(blkid -s UUID -o value "$DISK")
if ! grep -q "$UUID" /etc/fstab; then
    echo "Updating fstab..."
    echo "UUID=$UUID $MOUNT_POINT ext4 defaults,noatime 0 0" >> /etc/fstab
fi
mount -a
echo "Done! Mounted:"
df -h | grep longhorn
EOF

chmod +x setup_disk.sh
sudo ./setup_disk.sh
```

**Повтори это на всех 4-х воркерах.** После этого можно ставить чарт Longhorn.

Отлично. Раз диски смонтированы в `/mnt/longhorn-storage` на воркерах и `iscsid` запущен, мы готовы к развертыванию.

Самый важный момент сейчас — **указать Longhorn'у использовать именно эту папку**, иначе он начнет писать данные на системный диск (`/var/lib/longhorn` по умолчанию).

### Шаг 1. Добавление репозитория Helm

Выполняй на мастер-ноде:

```bash
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

### Шаг 2. Установка Longhorn

Мы установим Longhorn в неймспейс `longhorn-system`.
Я подготовил команду с правильными флагами под твою конфигурацию:

1.  `defaultSettings.defaultDataPath`: Указываем твой примонтированный диск `/mnt/longhorn-storage`.
2.  `persistence.defaultClassReplicaCount`: Ставим **3**. У тебя 4 воркера, три реплики обеспечат отличную отказоустойчивость (одна нода может упасть, данные будут доступны).
3.  `csi.kubeletRootDir`: Обычно `/var/lib/kubelet`. В RHEL/RedOS это стандарт, но если у тебя кастомный путь кублета, надо поправить (скорее всего, стандартный).

**Команда установки:**

```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultDataPath="/mnt/longhorn-storage" \
  --set persistence.defaultClassReplicaCount=3 \
  --set persistence.reclaimPolicy=Retain \
  --set defaultSettings.replicaSoftAntiAffinity=false
```

*   `replicaSoftAntiAffinity=false`: Это **жесткое правило**. Означает "Никогда не класть две копии данных на одну и ту же ноду". У тебя 4 воркера, так что это безопасно и правильно для продакшена.

### Шаг 3. Проверка запуска

Процесс запуска займет 2-5 минут. Longhorn поднимает много компонентов (manager, driver-deployer, csi-plugin, engine-image).

Следи за статусом:
```bash
kubectl get pods -n longhorn-system -w
```

Ты должен увидеть кучу подов. Главное, чтобы `longhorn-manager-*` на воркерах перешли в статус `Running`.

### Шаг 4. Настройка UI (Ingress)

Пока поды поднимаются, создадим доступ к красивой админке Longhorn.
Там нет встроенной авторизации, поэтому я добавил **Basic Auth** (логин/пароль), чтобы никто чужой не удалил твои диски.

1.  **Создаем файл паролей (htpasswd):**
    ```bash
    # Установи утилиту, если нет: dnf install httpd-tools
    # Создаем юзера admin с паролем (замени password на свой)
    htpasswd -c auth longhorn admin
    # Вводи пароль...
    
    # Создаем секрет в кубере
    kubectl create secret generic basic-auth --from-file=auth -n longhorn-system
    rm auth
    ```

2.  **Создаем Ingress (`k8s/longhorn-ingress.yaml`):**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ingress
  namespace: longhorn-system
  annotations:
    # Увеличиваем размер тела для загрузки бэкапов через UI, если понадобится
    nginx.ingress.kubernetes.io/proxy-body-size: 10000m
    # Подключаем Basic Auth
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: basic-auth
    nginx.ingress.kubernetes.io/auth-realm: 'Authentication Required - Longhorn'
spec:
  ingressClassName: nginx
  rules:
  - host: longhorn.ccsfarm.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
```

Примени:
```bash
kubectl apply -f k8s/longhorn-ingress.yaml
```

### Шаг 5. Финальная проверка

1.  Открой в браузере `http://longhorn.ccsfarm.local`.
2.  Введи логин/пароль.
3.  Ты должен увидеть Dashboard.
4.  **Самое важное:** Внизу страницы в блоке **Nodes** ты должен увидеть свои воркеры, и у каждого должно быть доступно около **50 GiB** места (Allocatable).

Если видишь 50 GiB — значит Longhorn увидел твои примонтированные диски `/mnt/longhorn-storage`.

**Как только убедишься, что UI работает и место видно — напиши, будем переносить NATS и Postgres на новые быстрые диски.**

Без проблем. Учитывая твою инфраструктуру (Internal CA + Cert-Manager), это делается через стандартные аннотации.

Тебе нужно обновить манифест Ingress. Я добавил секцию `tls` и аннотацию для `cert-manager`, чтобы он автоматически выпустил сертификат для `longhorn.ccsfarm.local`.

### Обновленный `k8s/longhorn-ingress.yaml`

**Важно:** В аннотации `cert-manager.io/cluster-issuer: "ca-issuer"` замени `ca-issuer` на имя твоего эмитента (ClusterIssuer), который смотрит на твой Internal CA. Обычно его называют `ca-issuer`, `internal-ca` или `vault-issuer`.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ingress
  namespace: longhorn-system
  annotations:
    # --- Настройки Nginx ---
    # Увеличиваем размер тела (для загрузки бэкапов/образов через UI)
    nginx.ingress.kubernetes.io/proxy-body-size: 10000m
    # Принудительный редирект на HTTPS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    
    # --- Авторизация (Basic Auth) ---
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: basic-auth
    nginx.ingress.kubernetes.io/auth-realm: 'Authentication Required - Longhorn'
    
    # --- SSL / Cert-Manager ---
    # Укажи здесь имя твоего ClusterIssuer
    cert-manager.io/cluster-issuer: "ccsfarm-ca-issuer " 
spec:
  ingressClassName: nginx
  # Секция TLS
  tls:
  - hosts:
    - longhorn.ccsfarm.local
    # Cert-manager создаст этот секрет автоматически
    secretName: longhorn-tls-secret
  rules:
  - host: longhorn.ccsfarm.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
```

### Как применить

1.  Примени файл:
    ```bash
    kubectl apply -f k8s/longhorn-ingress.yaml
    ```

2.  Проверь, что сертификат создался (через пару секунд):
    ```bash
    kubectl get certificate -n longhorn-system
    ```
    Статус должен быть `True`.

3.  Заходи на `https://longhorn.ccsfarm.local`. Браузер должен показать замочек (если CA добавлен в доверенные на твоем компе).

**P.S.** Если ты не помнишь имя своего ClusterIssuer, посмотри список доступных:
```bash
kubectl get clusterissuers
```
ccsfarm-ca-issuer 