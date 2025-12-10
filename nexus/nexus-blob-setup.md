# ============================================================================
# Инструкция: Создание Blob Stores в Nexus 3 с MinIO S3
# ============================================================================

## 📋 Предусловия

✅ Nexus 3 запущен и доступен на https://nexus.ccsfarm.local
✅ MinIO запущен с 3 buckets:
   - docker
   - dotnet
   - maven

---

## 🔐 Шаг 1: Получить credentials для MinIO

**В консоли MinIO или K8s secret найдите:**
- Access Key (login)
- Secret Key (password)
- Endpoint: `http://minio.minio:9000` (или ваш адрес MinIO в кластере)

Пример:
```bash
# Если MinIO в Kubernetes:
kubectl get secret -n minio minio -o jsonpath='{.data.root-user}' | base64 -d
kubectl get secret -n minio minio -o jsonpath='{.data.root-password}' | base64 -d
```

---

## 🎯 Шаг 2: Зайти в Nexus Admin

1. Откройте: **https://nexus.ccsfarm.local**
2. Логин: `admin`
3. Пароль: (из `/nexus-data/admin.password`)
4. Перейти в **⚙️ Administration** (верхний правый угол)

---

## 📦 Шаг 3: Создать S3 Blob Store для Docker

1. В левом меню: **Repository** → **Blob Stores**
2. Нажать **Create blob store** (синяя кнопка)
3. Выбрать **Amazon S3** из выпадающего списка
4. Заполнить форму:

| Поле | Значение |
|------|----------|
| **Name** | `docker-blob` |
| **S3 Bucket** | `docker` |
| **S3 Endpoint URL** | `http://minio.minio:9000` |
| **Authentication Type** | `Static` |
| **Access Key** | (ваш Access Key из MinIO) |
| **Secret Access Key** | (ваш Secret Key из MinIO) |
| **Region** | `us-east-1` |
| **Signature Version** | `AWS Signature Version 4` |
| **Force Path Style** | ✅ **Включить** (важно для MinIO!) |
| **Assume Role** | ❌ (оставить пусто) |
| **Bucket Prefix** | (оставить пусто) |

5. Нажать **Create blob store**

---

## 📦 Шаг 4: Создать S3 Blob Store для Maven

Повторить Шаг 3, но:

| Поле | Значение |
|------|----------|
| **Name** | `maven-blob` |
| **S3 Bucket** | `maven` |
| *(остальное как в docker-blob)* | |

---

## 📦 Шаг 5: Создать S3 Blob Store для .NET

Повторить Шаг 3, но:

| Поле | Значение |
|------|----------|
| **Name** | `dotnet-blob` |
| **S3 Bucket** | `dotnet` |
| *(остальное как в docker-blob)* | |

---

## ✅ Проверка

После создания всех трёх Blob Stores, в **Blob Stores** должны видны:

```
Name            Type        Backend Storage
docker-blob     S3          docker (MinIO)
dotnet-blob     S3          dotnet (MinIO)
maven-blob      S3          maven (MinIO)
```

---

## 🐳 Шаг 6: Создать Docker Repository

1. **Repository** → **Repositories**
2. **Create repository** → **docker (hosted)**
3. Заполнить:

| Поле | Значение |
|------|----------|
| **Name** | `docker-hosted` |
| **HTTP Port** | `8082` |
| **Blob Store** | `docker-blob` ✅ |
| **Cleanup Policy** | (оставить дефолт) |

4. **Create repository**

---

## 📚 Шаг 7: Создать Maven Repositories

### 7a. Maven Releases
1. **Create repository** → **maven2 (hosted)**
2. Заполнить:

| Поле | Значение |
|------|----------|
| **Name** | `maven-releases` |
| **Blob Store** | `maven-blob` ✅ |
| **Version Policy** | `Release` |
| **Layout Policy** | `Strict` |

3. **Create repository**

### 7b. Maven Snapshots
1. **Create repository** → **maven2 (hosted)**
2. Заполнить:

| Поле | Значение |
|------|----------|
| **Name** | `maven-snapshots` |
| **Blob Store** | `maven-blob` ✅ |
| **Version Policy** | `Snapshot` |
| **Layout Policy** | `Strict` |

3. **Create repository**

---

## 🧪 Шаг 8: Тест - Push Docker образа

```bash
# 1. Залогиниться в Nexus Registry
docker login registry-nexus.ccsfarm.local
# Username: admin
# Password: (ваш пароль)
# ⚠️ Если ошибка с сертификатом - добавьте CA сертификат на клиент

# 2. Пуллить тестовый образ
docker pull alpine:latest

# 3. Тегировать для Nexus
docker tag alpine:latest registry-nexus.ccsfarm.local/test-app:v1.0.0

# 4. Пушить в Nexus
docker push registry-nexus.ccsfarm.local/test-app:v1.0.0

# 5. Проверить в Nexus UI
# Repository → docker-hosted → должен появиться test-app
```

---

## 🧪 Шаг 9: Проверить в MinIO

```bash
# Зайти в MinIO Console
# https://minio.ccsfarm.local (или ваш адрес)

# Перейти в bucket: docker
# Должны видны файлы: test-app/v1.0.0/...
```

---

## ⚠️ Troubleshooting

### Ошибка: "Unable to connect to S3"
- ✅ Проверить что MinIO доступен: `curl -k http://minio.minio:9000`
- ✅ Access Key / Secret Key верны
- ✅ Force Path Style = ON

### Ошибка: "Bucket does not exist"
- ✅ Проверить что bucket создан: `mc ls minio/docker`
- ✅ Имя bucket точно совпадает

### Docker push ошибка с TLS
```bash
# На клиенте добавить CA cert
sudo mkdir -p /etc/docker/certs.d/registry-nexus.ccsfarm.local
sudo cp /path/to/ca.crt /etc/docker/certs.d/registry-nexus.ccsfarm.local/ca.crt
sudo systemctl restart docker
```

---

## 📝 Итого

✅ 3 Blob Stores (docker, maven, dotnet) на MinIO S3
✅ Docker Repository на docker-blob
✅ Maven Releases/Snapshots на maven-blob
✅ .NET Repository на dotnet-blob (если нужен)

Система готова к использованию! 🚀
