############### Пероесборка образа в ручную в кубе. #############################

### ШАГ 1: Подготовка "Исходного кода" (Dockerfile)

GitLab сам выкачивает код. Мы сымитируем это, положив Dockerfile в ConfigMap.

*(Использую тот текст Dockerfile, который ты прислал ранее для Postgres)*

```bash
# Создаем файл локально
cat <<EOF > Dockerfile
FROM timescale/timescaledb:latest-pg16
USER root
RUN apk update && apk add --no-cache git build-base clang19 llvm19
RUN cd /tmp && git clone --branch v0.7.0 https://github.com/pgvector/pgvector.git && cd pgvector && make && make install
RUN rm -rf /tmp/pgvector && apk del git build-base clang19 llvm19
USER postgres
EOF

# Создаем ConfigMap (это аналог git clone для одного файла)
kubectl create configmap dockerfile-cm --from-file=Dockerfile=Dockerfile --dry-run=client -o yaml | kubectl apply -f -
```

### ШАГ 2: Подготовка Авторизации (Auth)

GitLab делает `echo ... > /kaniko/.docker/config.json`. Мы сделаем это через Kubernetes Secret.

```bash
# Удаляем старый, чтобы не было конфликтов
kubectl delete secret nexus-creds

# Создаем секрет для ТОЧНОГО имени хоста
kubectl create secret docker-registry nexus-creds \
  --docker-server=registry-nexus.ccsfarm.local \
  --docker-username=gitlab \
  --docker-password=FeerDe3o \
  --docker-email=admin@example.com
```

### ШАГ 3: Подготовка Сертификата (TLS)

В пайплайне ты монтируешь `/custom-certs/gitlab.ccsfarm.local.crt`. Нам нужно достать этот сертификат из кластера (это CA или сам сертификат Nexus) и подложить его Kaniko.

Так как у тебя `cert-manager` и `nexus-tls-secret`, возьмем публичный ключ оттуда.

```bash
# Достаем сертификат из секрета Nexus и кладем в ConfigMap
kubectl get secret -n nexus nexus-tls-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > nexus.crt

# Создаем ConfigMap с сертификатом
kubectl create configmap nexus-cert-cm --from-file=nexus.crt=nexus.crt --dry-run=client -o yaml | kubectl apply -f -
```

### ШАГ 4: Запуск "Ручного Пайплайна"

Вот манифест, который на 100% повторяет твой `.gitlab-ci.yml`.

Я добавил `hostAliases`, чтобы эмулировать поведение внешней сети (разрешить домен в IP Ingress), так как внутри кластера DNS может вести себя иначе.

Создай файл `manual-pipeline.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-manual-build
spec:
  # Эмуляция DNS: говорим, что registry-nexus находится на IP Ingress-контроллера
  # (Вставь сюда IP своего Ingress, например 10.10.2.111)
  hostAliases:
  - ip: "10.10.2.111"
    hostnames:
    - "registry-nexus.ccsfarm.local"

  containers:
  - name: kaniko
    # Тот же образ, что в пайплайне
    image: gcr.io/kaniko-project/executor:v1.14.0-debug
    args:
    - "--context=/workspace"
    - "--dockerfile=/workspace/Dockerfile"
    # Тот же дестинейшн
    - "--destination=registry-nexus.ccsfarm.local/pg-ts-vector:latest"
    # === КЛЮЧЕВОЙ МОМЕНТ ИЗ ТВОЕГО ПАЙПЛАЙНА ===
    # Говорим Kaniko использовать конкретный файл сертификата для этого домена
    - "--registry-certificate=registry-nexus.ccsfarm.local=/custom-certs/nexus.crt"
    # Отключаем TLS Verify глобально (сертификат выше обеспечит доверие)
    # или можно оставить --skip-tls-verify=false, если сертификат валиден
    
    volumeMounts:
    - name: workspace
      mountPath: /workspace
    - name: kaniko-secret
      mountPath: /kaniko/.docker/
    - name: custom-certs
      mountPath: /custom-certs
      
  restartPolicy: Never
  volumes:
  # 1. Исходный код (Dockerfile)
  - name: workspace
    configMap:
      name: dockerfile-cm
  # 2. Авторизация (config.json)
  - name: kaniko-secret
    projected:
      sources:
      - secret:
          name: nexus-creds
          items:
            - key: .dockerconfigjson
              path: config.json
  # 3. Сертификаты (аналог /custom-certs)
  - name: custom-certs
    configMap:
      name: nexus-cert-cm
```

### Запуск

```bash
kubectl delete pod kaniko-manual-build --force --grace-period=0
kubectl apply -f manual-pipeline.yaml
kubectl logs -f kaniko-manual-build
```

**В чем разница с прошлыми попытками:**
1.  Мы явно передаем `--registry-certificate`, как в твоем рабочем CI.
2.  Мы монтируем сертификат через ConfigMap.
3.  Мы используем `hostAliases`, чтобы Kaniko, находясь внутри кластера, пошел через Ingress (внешний IP), а не пытался искать внутренние сервисы. Это позволяет сохранить схему с портом 8082, которую обрабатывает Ingress.