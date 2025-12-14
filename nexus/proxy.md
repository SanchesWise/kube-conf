Это классическая задача для Nexus. Чтобы реализовать схему **"Сначала ищем у себя, если нет — качаем из интернета и сохраняем себе"**, используется паттерн **Group Repository**.

Нам нужно создать три сущности в Nexus:
1.  **Hosted** (уже есть) — для ваших локальных сборок.
2.  **Proxy** (надо создать) — это "шлюз" в Docker Hub, который будет кэшировать всё, что через него проходит.
3.  **Group** (надо создать) — это единый вход, который объединяет первые два.

И затем мы перенастроим Ingress и CRI-O на этот Group-репозиторий.

---

### ШАГ 1: Настройка S3 для кэша (MinIO)

Лучше хранить кэш Docker Hub в отдельном бакете, чтобы он не замусорил ваши личные образы, и его можно было легко чистить.

1.  Зайдите в **MinIO Console** и создайте бакет: **`nexus-docker-proxy`**.
2.  Зайдите в **Nexus UI** -> **Blob Stores** -> **Create Blob Store** -> **S3**.
    *   Name: `docker-proxy-blob`
    *   Bucket: `nexus-docker-proxy`
    *   Endpoint: `http://minio.minio.svc.cluster.local:9000`
    *   **Use path-style access**: ✅ (Обязательно!)
    *   Остальные креды как раньше.

---

### ШАГ 2: Создание Proxy репозитория (Кэш Docker Hub)

Этот репозиторий будет ходить в интернет за вас.

1.  **Settings** -> **Repositories** -> **Create repository** -> **docker (proxy)**.
2.  Заполняем:
    *   **Name**: `docker-proxy`.
    *   **HTTP Port**: Оставьте пустым! (мы работаем через порт 8081).
    *   **Enable Docker V1 API**: Не нужно.
    *   **Proxy -> Remote Storage**: `https://registry-1.docker.io`
    *   **Proxy -> Docker Index**: `Use Docker Hub` (выбрано по умолчанию).
    *   **Storage -> Blob store**: `docker-proxy-blob` (тот, что создали в шаге 1).
3.  **Save**.

*Совет: Если у вас есть аккаунт Docker Hub, можно ввести логин/пароль в секции "HttpClient authentication", чтобы увеличить лимиты скачивания, но пока можно и без этого.*

---

### ШАГ 3: Создание Group репозитория (Единая точка входа)

Это и есть тот "виртуальный" репозиторий, на который мы переключим весь кластер.

1.  **Create repository** -> **docker (group)**.
2.  Заполняем:
    *   **Name**: `docker-all` (или `docker-group`).
    *   **HTTP Port**: Оставьте пустым.
    *   **Storage -> Blob store**: `default` (для группы это метаданные, места не занимают).
    *   **Group -> Member repositories**:
        *   Перенесите `docker-hosted` вправо.
        *   Перенесите `docker-proxy` вправо.
        *   **ВАЖНО:** Порядок имеет значение! Сначала `hosted` (ищем своё), потом `proxy` (ищем в интернете).
3.  **Save**.

---

### ШАГ 4: Переключение Ingress на Group

Сейчас ваш Ingress `registry-nexus.ccsfarm.local` смотрит только в `docker-hosted`. Надо направить его в `docker-all`.

Отредактируйте `nexus-final.yaml` (измените только одну строчку с `rewrite-target`):

```yaml
    # === ИЗМЕНЕНИЕ ЗДЕСЬ ===
    # Было: /repository/docker-hosted/$2
    # Стало: /repository/docker-all/$2
    nginx.ingress.kubernetes.io/rewrite-target: /repository/docker-all/$2
```

Примените:
```bash
kubectl apply -f nexus-final.yaml
```

**Что изменилось:** Теперь, когда вы пушите — вы пушите в группу (Nexus умный, он сам поймет, что пушить можно только в hosted часть). Когда качаете — он ищет сначала в hosted, потом в proxy.

---

### ШАГ 5: Настройка CRI-O на всех нодах (Самое главное)

Теперь нужно сказать всем нодам кластера: "Когда кто-то просит `docker.io/nginx`, не иди в интернет, иди в `registry-nexus.ccsfarm.local`".

Мы используем скрипт для обновления конфигов на всех нодах сразу (как мы делали раньше).

Создайте файл `update-registry-mirror.sh`:

```bash
#!/bin/bash

# Список всех нод
NODES=(
    "k8s-master.ccsfarm.local"
    "k8s-control01.ccsfarm.local"
    "k8s-control02.ccsfarm.local"
    "k8s-worker01.ccsfarm.local"
    "k8s-worker02.ccsfarm.local"
    "k8s-worker03.ccsfarm.local"
    "k8s-worker04.ccsfarm.local"
)

# Новый конфиг: перенаправляем docker.io в наш Nexus
cat <<EOF > local_registries.conf
# 1. Наш локальный регистри (разрешаем без HTTPS проверки внутри CRI-O)
[[registry]]
  location = "registry-nexus.ccsfarm.local"
  insecure = true

# 2. Перехват docker.io
[[registry]]
  prefix = "docker.io"
  location = "registry-nexus.ccsfarm.local" # Весь трафик идет сюда
  insecure = true # Self-signed cert

# 3. Резервные зеркала (на случай если Nexus умрет)
# Можно раскомментировать, если хотите fallback в интернет
# [[registry.mirror]]
#   location = "mirror.gcr.io"
EOF

echo "Начинаем обновление конфигов registry..."

for NODE in "${NODES[@]}"; do
    echo "--- $NODE ---"
    scp -o StrictHostKeyChecking=no -q local_registries.conf "$NODE:/tmp/registries.conf"
    
    # Мы уже настроили sudo без пароля в прошлом шаге, так что просто выполняем
    ssh -o StrictHostKeyChecking=no "$NODE" "sudo mv /tmp/registries.conf /etc/containers/registries.conf && sudo systemctl reload crio"
    
    if [ $? -eq 0 ]; then
        echo "✅ OK"
    else
        echo "❌ ERROR"
    fi
done

rm local_registries.conf
```

Запустите:
```bash
chmod +x update-registry-mirror.sh
./update-registry-mirror.sh
```

---

### ШАГ 6: Проверка

Теперь самое интересное. Проверим, закэширует ли Nexus образ.

1.  **Удалите локальный кэш образа на ноде (например, nginx):**
    ```bash
    sudo crictl rmi docker.io/library/nginx:latest || true
    ```

2.  **Скачайте его через crictl (притворяемся кубером):**
    *Обратите внимание: мы просим `docker.io`, но скачиваться он будет через Nexus.*
    ```bash
    # Требуется авторизация, т.к. наш Nexus закрыт
    sudo crictl pull --creds "gitlab:FeerDe3o" docker.io/library/nginx:latest
    ```

3.  **Проверьте Nexus UI:**
    *   Зайдите в Nexus -> **Browse** -> **docker-proxy**.
    *   Вы должны увидеть там папку `library/nginx`.

**Итог:**
*   Если образ есть в `docker-hosted` -> отдастся локально.
*   Если нет -> Nexus скачает с Docker Hub, сохранит в MinIO (бакет `nexus-docker-proxy`) и отдаст вам.
*   В следующий раз, даже если Интернет отключить, образ отдастся из MinIO.

**Важно:** Для `crictl` и Kubernetes вам теперь всегда нужны `imagePullSecrets` (или `config.json` с авторизацией), даже для публичных образов, потому что теперь доступ к ним идет через ваш приватный Nexus.