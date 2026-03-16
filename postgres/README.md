Это техническая документация по развернутому отказоустойчивому кластеру PostgreSQL 16. Кластер построен по архитектуре **Patroni + etcd + HAProxy + Keepalived** внутри LXC-контейнеров на платформе Proxmox.

---

## 1. Общая архитектура решения
Кластер обеспечивает высокую доступность (HA) с автоматическим выбором лидера (failover).
*   **DCS (Distributed Configuration Store):** `etcd` — хранит состояние кластера и кворум.
*   **Менеджер кластера:** `Patroni` — управляет жизненным циклом инстансов Postgres.
*   **Балансировка и точка входа:** `HAProxy` — направляет трафик на текущего мастера.
*   **Виртуальный IP (VIP):** `Keepalived` — обеспечивает единый адрес для подключения.

---

## 2. Технические параметры и адресация

### Сетевая конфигурация (Домен: .ccsfarm.local)
| Имя ноды | IP адрес | Роль в ОС | Размещение (Proxmox) |
| :--- | :--- | :--- | :--- |
| **pg-cluster** | **10.10.2.130** | **Virtual IP (VIP)** | Перемещается (Keepalived) |
| pg-01 | 10.10.2.131 | etcd, Patroni, HAProxy | chia04 |
| pg-02 | 10.10.2.132 | etcd, Patroni, HAProxy | chia03 |
| pg-03 | 10.10.2.133 | etcd, Patroni, HAProxy | gpu-prox |

### Параметры ПО
*   **ОС:** Debian 13 (Trixie)
*   **СУБД:** PostgreSQL 16.x
*   **Расширения:** 
    *   TimescaleDB 2.x (Лицензия: **timescale** — полная версия с поддержкой сжатия).
    *   pgvector (Библиотека: `vector.so`).
*   **Порты:**
    *   `5432`: Точка входа (HAProxy) и сам PostgreSQL.
    *   `2379 / 2380`: etcd клиент/пир.
    *   `8008`: Patroni API (Health-check для HAProxy).

---

## 3. Особенности реализации

1.  **Лицензирование TimescaleDB:** Установлена полная версия из репозитория `packagecloud.io`. Лицензия переведена из `apache` в `timescale` через параметры Patroni для поддержки сжатых чанков и непрерывных агрегатов.
2.  **Локаль:** В целях совместимости и стабильности при миграции из старых бэкапов используется локаль `C.UTF-8`.
3.  **Конфигурация через DCS:** Все настройки PostgreSQL (включая `shared_preload_libraries`, `max_connections`, `timescaledb.license`) управляются централизованно через `patronictl edit-config`. Ручные правки в `postgresql.conf` игнорируются.
4.  **Сетевой стек:** Включен параметр ядра `net.ipv4.ip_nonlocal_bind=1`, что позволяет HAProxy запускаться на всех нодах, даже если VIP в данный момент не активен на конкретной ноде.

---

## 4. Обслуживание кластера (Основные команды)

### Проверка статуса
```bash
# Просмотр состояния всех нод и репликации
patronictl -c /etc/patroni/config.yml list
```

### Изменение конфигурации
```bash
# Редактирование параметров всей базы данных
patronictl -c /etc/patroni/config.yml edit-config
```

### Переключение Лидера (Switchover)
Если нужно выполнить плановые работы на мастере:
```bash
patronictl -c /etc/patroni/config.yml switchover
```

### Перезапуск нод
```bash
# Безопасный перезапуск через Patroni
patronictl -c /etc/patroni/config.yml restart pg-cluster [node_name]
```

---

## 5. Базовый траблшутинг

### Ошибка: `psql: error: connection failed: received invalid response ... H`
*   **Симптом:** При попытке подключения через VIP вы получаете ошибку с буквой "H".
*   **Причина:** HAProxy не видит живого Лидера и отдает HTTP-страницу с ошибкой 503.
*   **Решение:**
    1. Проверьте `patronictl list` — есть ли в кластере Лидер в статусе `running`.
    2. Проверьте на Лидере: `curl -I http://localhost:8008/master`. Должен быть код `200 OK`.
    3. Проверьте логи HAProxy: `journalctl -u haproxy -f`.

### Ошибка: `could not access file "$libdir/timescaledb-tsl-..."`
*   **Причина:** Установлена версия `postgresql-16-timescaledb` (OSS) вместо полной версии `timescaledb-2-postgresql-16`, либо не обновлено расширение в базе.
*   **Решение:** Установите правильный пакет и выполните `ALTER EXTENSION timescaledb UPDATE;` во всех базах.

### Ошибка: `FATAL: no pg_hba.conf entry for host ...`
*   **Причина:** Новая нода или HAProxy пытаются подключиться, но их IP нет в белом списке.
*   **Решение:** Добавьте подсеть в конфиг через `edit-config`:
    ```yaml
    postgresql:
      pg_hba:
        - host all all 10.10.2.0/24 md5
    ```

### Ошибка: `invalid LC_COLLATE locale name`
*   **Причина:** В дампе указана локаль (например, `en_US.utf8`), которой нет в текущей ОС.
*   **Решение:** Сгенерируйте локаль в ОС (`dpkg-reconfigure locales`) или при восстановлении делайте замену через `sed` на `C.UTF-8`.

### Проблемы с etcd (Timeout)
*   **Симптом:** Patroni пишет `ReadTimeoutError` или не может получить список машин.
*   **Решение:** 
    1. Проверьте связность: `etcdctl --endpoints=... endpoint health`.
    2. Если etcd в LXC, проверьте Disk IO на хосте Proxmox. Высокие задержки записи (fsync) могут разваливать кворум etcd.

---

## 6. Резервное копирование
На текущий момент настроено логическое резервное копирование (`pg_dumpall`). 
*   **Рекомендация:** Для баз объемом более 100ГБ рассмотреть внедрение **pgBackRest**, который поддерживает инкрементальные бэкапы и восстановление на любой момент времени (PITR).













<!-- 
### Шаг 1. Апгрейд PostgreSQL (Добавление `pgvector`)

Твой текущий образ `timescale/timescaledb:latest-pg16` не содержит расширения для работы с векторами. Нам нужно собрать свой образ.

**1. Создай файл `docker/postgres/Dockerfile`:**

```dockerfile
# Берем за основу официальный TimescaleDB (он на базе Alpine или Debian)
FROM timescale/timescaledb:latest-pg16

USER root

# Установка зависимостей для сборки pgvector
RUN apk add --no-cache git build-base clang llvm15

# Скачивание и сборка pgvector
RUN cd /tmp && \
    git clone --branch v0.7.0 https://github.com/pgvector/pgvector.git && \
    cd pgvector && \
    make && \
    make install

# Очистка мусора
RUN rm -rf /tmp/pgvector && \
    apk del git build-base clang llvm15

USER postgres
```

**2. Собери и запушь образ (команды примерные):**
```bash
docker build -t registry-nexus.ccsfarm.local/timescale-vector:pg16 ./docker/postgres/
docker push registry-nexus.ccsfarm.local/timescale-vector:pg16
```

**3. Обнови StatefulSet в Kubernetes:**
*   Сделай **бэкап базы** (`pg_dumpall`).
*   Отредактируй манифест Postgres: замени `image` на твой новый `timescale-vector:pg16`.
*   Удали под `postgres-0`, чтобы он пересоздался.

**4. Активируй расширение:**
Зайди в базу через `psql` и выполни:
```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

#### Бэкапы ###############

Переход на кастомный образ с `pgvector` — это, по сути, апгрейд системных библиотек. Хотя данные на диске (PV) сохраняются, всегда есть риск несовместимости бинарников или проблем при старте контейнера.

Есть три способа сделать бэкап. Для твоей текущей задачи (миграция) лучше всего подходит **Способ 1**, а на будущее настрой **Способ 2**.

---

### Способ 1. "Ручной" бэкап (Логический дамп)
Самый надежный способ перед обновлением. Мы выгружаем чистый SQL. Если новый образ не запустится или повредит файлы данных, мы просто поднимем чистый Postgres и зальем туда этот SQL.

Выполни эту команду с машины, где есть `kubectl` (твоего ноута или мастер-ноды):

```bash
# 1. Создаем дамп всех баз данных (включая схемы и юзеров)
# -c: добавляет команды CLEAN (DROP) перед созданием
# --if-exists: добавляет защиту от ошибок, если удалять нечего
kubectl exec -t postgres-0 -- pg_dumpall -c --if-exists -U sanches > full_backup_$(date +%F_%H-%M).sql

# 2. Проверяем, что файл не пустой
ls -lh full_backup_*.sql
```

*Этот файл сохрани к себе локально или закинь в S3 вручную.*

---

### Способ 2. Автоматический бэкап в MinIO (CronJob)
Это решение для "Production Ready". Раз у тебя уже есть MinIO, грех им не пользоваться. Мы создадим CronJob, который каждую ночь делает дамп, сжимает его и отправляет в бакет `backups`.

**1. Создай бакет `backups` в MinIO** (если нет).

**2. Манифест `k8s/db-backup-cronjob.yaml`**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup-to-s3
  namespace: prod # Или где у тебя живет база
spec:
  schedule: "0 2 * * *" # Каждый день в 2:00 ночи
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            # Используем образ с aws-cli и pg_dump
            image: bitnami/postgresql:16
            command: ["/bin/sh", "-c"]
            args:
              - |
                set -e
                echo "Starting backup..."
                
                # 1. Формируем имя файла
                FILENAME=db_backup_$(date +%Y-%m-%d_%H-%M).sql.gz
                
                # 2. Делаем дамп и сжимаем на лету
                # PGPASSWORD берется из env
                pg_dumpall -h postgres-headless -U $POSTGRES_USER | gzip > /tmp/$FILENAME
                
                echo "Backup created: size $(du -h /tmp/$FILENAME | cut -f1)"
                
                # 3. Устанавливаем MinIO Client (mc) или используем curl/aws-cli
                # Тут простой вариант через curl (REST API MinIO)
                # Вычисляем сигнатуру или просто используем s3cmd/aws-cli если они есть в образе.
                # НО! Проще всего в alpine установить aws-cli.
                
                # Чтобы не усложнять скрипт, используем готовый образ с AWS CLI,
                # но нам нужен и pg_dump. Поэтому сделаем chained-контейнеры или простой скрипт на python.
                
                # ДАВАЙ ПРОЩЕ: Используем образ minio/mc, но в нем нет pg_dump.
                # Комбинированный вариант:
                
            envFrom:
            - secretRef:
                name: postgres-secret
            - secretRef:
                name: minio-creds
          
          # РЕКОМЕНДУЕМЫЙ ВАРИАНТ:
          # Использовать готовый docker-образ для бэкапов pg->s3
          # Например: prodrigestivill/postgres-backup-local
          # Но у нас свой MinIO.
          
          # Давай напишем чистовой вариант на Python (у тебя python-пайплайн отлажен)
          # Это будет Sidecar или Job
          
          restartPolicy: OnFailure
```

Поскольку писать bash-скрипты с `curl` для S3 авторизации — это боль, давай используем твой опыт с Python.

**Python-скрипт для бэкапа (`backup.py`):**
(Ты можешь собрать его в образ `registry-nexus.../pg-backup:v1` через свой пайплайн `Makeimage`, добавив туда `postgresql-client`).

**Dockerfile для бэкапера:**
```dockerfile
FROM python:3.9-slim
# Ставим клиент постгреса для утилиты pg_dump
RUN apt-get update && apt-get install -y postgresql-client && rm -rf /var/lib/apt/lists/*
RUN pip install minio
COPY backup.py .
CMD ["python", "backup.py"]
```

**Скрипт `backup.py`:**
```python
import os
import time
import subprocess
from datetime import datetime
from minio import Minio

# Конфиги
DB_HOST = os.getenv("DB_HOST", "postgres-headless")
DB_USER = os.getenv("POSTGRES_USER")
DB_PASS = os.getenv("POSTGRES_PASSWORD")
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "minio.minio.svc.cluster.local:9000")
MINIO_KEY = os.getenv("MINIO_ACCESS_KEY") # Из секрета minio-creds (access-key)
MINIO_SECRET = os.getenv("MINIO_SECRET_KEY") # Из секрета minio-creds (secret-key)
BUCKET = "backups"

def main():
    date_str = datetime.now().strftime("%Y-%m-%d_%H-%M")
    filename = f"pg_backup_{date_str}.sql.gz"
    
    print(f"Starting backup: {filename}")
    
    # 1. Запуск pg_dumpall через subprocess (пайп в gzip)
    # PGPASSWORD передаем через env для безопасности
    env = os.environ.copy()
    env["PGPASSWORD"] = DB_PASS
    
    dump_cmd = f"pg_dumpall -h {DB_HOST} -U {DB_USER} --clean --if-exists | gzip"
    
    with open(filename, "wb") as f_out:
        # shell=True нужен для пайпов (|)
        process = subprocess.Popen(dump_cmd, shell=True, env=env, stdout=f_out, stderr=subprocess.PIPE)
        _, stderr = process.communicate()
        
        if process.returncode != 0:
            print(f"Error creating dump: {stderr.decode()}")
            exit(1)
            
    print(f"Dump created locally. Size: {os.path.getsize(filename)} bytes")

    # 2. Загрузка в MinIO
    client = Minio(MINIO_ENDPOINT, access_key=MINIO_KEY, secret_key=MINIO_SECRET, secure=False)
    
    if not client.bucket_exists(BUCKET):
        client.make_bucket(BUCKET)
        
    client.fput_object(BUCKET, filename, filename)
    print("Uploaded to MinIO successfully.")
    
    # Удаляем локальный файл
    os.remove(filename)

if __name__ == "__main__":
    main()
```

---

### Способ 3. Velero (Инфраструктурный)
Так как в описании кластера сказано: *"Velero (Apps & Data) ... Хранилище: S3 MinIO"*, это самый простой путь.

Если у тебя настроен Velero с поддержкой снапшотов (Restic/Kopia) для PVC:

```bash
# Создать бэкап неймспейса prod (где база)
velero backup create db-upgrade-backup --include-namespaces prod --wait
```

Это создаст копию всего: и манифестов, и содержимого диска.
**Минус:** Это "File System Backup". При восстановлении база может ругаться на некорректное выключение (Crash Recovery), но данные сохранятся. Для Postgres лучше делать `pg_dump` (Способ 1), но Velero — отличная страховка.

### Резюме: Как действовать сейчас

1.  **Сделай Способ 1 (Ручной дамп)**. Это обязательно перед сменой образа.
    ```bash
    kubectl exec postgres-0 -- pg_dumpall -U sanches > backup_pre_vector.sql
    ```
2.  **Обнови StatefulSet:** Поменяй имидж на свой `timescale-vector:pg16`.
3.  **Перезапусти под:** `kubectl delete pod postgres-0`.
4.  **Проверь логи:** `kubectl logs -f postgres-0`. Если он запустился и пишет "database system is ready to accept connections" — всё супер.
5.  **Активируй:** Зайди внутрь и сделай `CREATE EXTENSION vector;`.

Если что-то пойдет не так (под уйдет в CrashLoop), просто верни старый image в манифесте, и он поднимется. Если данные повредятся (маловероятно при смене минорной версии или добавлении расширения), у тебя есть `backup_pre_vector.sql`.
 -->
