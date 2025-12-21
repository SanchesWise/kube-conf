Мы будем использовать Prometheus Operator (kube-prometheus-stack). Это "золотой стандарт" для Kubernetes, который сразу ставит Prometheus, Alertmanager, Grafana и Node Exporter (для метрик железа).
Вот пошаговый план:
Подготовка сертификатов (Grafana будет доступна по HTTPS).
Установка основного стека (Prometheus + Grafana).
Подключение баз данных (Postgres, Redis) через экспортеры.
Подключение мониторинга сертификатов (Cert-Manager).
Шаг 1. Сертификаты для Grafana и Alertmanager
Раз у нас есть свой CA, давайте сделаем красивые HTTPS ссылки. Создайте файл monitoring-certs.yaml:



Yaml

apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-tls
  namespace: monitoring # Мы создадим этот namespace позже
spec:
  secretName: grafana-tls-secret
  dnsNames:
    - grafana.ccsfarm.local
  issuerRef:
    name: ccsfarm-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: alertmanager-tls
  namespace: monitoring
spec:
  secretName: alertmanager-tls-secret
  dnsNames:
    - alertmanager.ccsfarm.local
  issuerRef:
    name: ccsfarm-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io


Шаг 2. Конфигурация стека (values.yaml)
Создайте файл monitoring-values.yaml. Я настроил его под вашу NFS и Ingress.

Yaml
# monitoring-values.yaml

# 1. Настройки Grafana
grafana:
  # Пароль администратора (по умолчанию admin / prom-operator)
  # Лучше задать свой
  adminPassword: "admin" 
  
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - grafana.ccsfarm.local
    tls:
      - secretName: grafana-tls-secret # Наш сертификат
        hosts:
          - grafana.ccsfarm.local
  
  persistence:
    enabled: true
    storageClassName: managed-nfs-storage
    size: 10Gi

  # Дополнительные плагины (опционально)
  plugins:
    - grafana-piechart-panel

# 2. Настройки Prometheus
prometheus:
  prometheusSpec:
    # Сколько хранить метрики (по умолчанию 10 дней, ставим 30)
    retention: 30d
    
    # Хранилище для метрик
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-nfs-storage
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    
    # ВАЖНО: Разрешаем Прометеусу искать ServiceMonitor в других неймспейсах
    # Без этого он не увидит Redis/Postgres/Cert-manager
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}

# 3. Alertmanager (Уведомления)
alertmanager:
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - alertmanager.ccsfarm.local
    tls:
      - secretName: alertmanager-tls-secret
        hosts:
          - alertmanager.ccsfarm.local
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-nfs-storage
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi

# 4. Мониторинг компонентов K8s
# Отключаем то, что может конфликтовать в облаках, но для on-prem (RED OS) включаем всё
kubeControllerManager:
  enabled: true
kubeEtcd:
  enabled: true
kubeScheduler:
  enabled: true
coreDns:
  enabled: true # Мониторинг DNS
kubelet:
  enabled: true # Мониторинг контейнеров

Шаг 3. Установка стека
Выполните команды на Control-plane ноде:
code
Bash

# 1. Создаем namespace
kubectl create namespace monitoring

# 2. Создаем сертификаты (из Шага 1)
kubectl apply -f monitoring-certs.yaml

# 3. Добавляем репозиторий Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 4. Устанавливаем стек
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f monitoring-values.yaml


Шаг 4. Мониторинг баз данных (Экспортеры)
Postgres и Redis работают отдельно, поэтому нам нужно запустить к ним "агентов" (экспортеры), которые будут переводить их метрики на язык Prometheus.
Создайте файл db-exporters.yaml.
⚠️ ВАЖНО: Замените YOUR_REDIS_PASSWORD и YOUR_POSTGRES_PASSWORD на реальные пароли.
code
Yaml


# Секрет с доступами к БД
apiVersion: v1
kind: Secret
metadata:
  name: db-exporter-secrets
  namespace: monitoring
type: Opaque
stringData:
  # Подключение к Redis (имя сервиса:порт)
  redis-addr: "redis.redis.svc.cluster.local:6379"
  redis-password: "YOUR_REDIS_PASSWORD" 
  
  # Подключение к Postgres
  # Формат: postgresql://user:password@host:port/dbname?sslmode=disable
  postgres-conn: "postgresql://postgres:YOUR_POSTGRES_PASSWORD@postgres-np.postgres.svc.cluster.local:5432/postgres?sslmode=disable"

---
# -------------------
# 1. REDIS EXPORTER
# -------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-exporter
  template:
    metadata:
      labels:
        app: redis-exporter
    spec:
      containers:
      - name: redis-exporter
        image: oliver006/redis_exporter:v1.55.0
        env:
        - name: REDIS_ADDR
          valueFrom: { secretKeyRef: { name: db-exporter-secrets, key: redis-addr } }
        - name: REDIS_PASSWORD
          valueFrom: { secretKeyRef: { name: db-exporter-secrets, key: redis-password } }
        ports:
        - containerPort: 9121
          name: metrics

---
apiVersion: v1
kind: Service
metadata:
  name: redis-exporter
  namespace: monitoring
  labels:
    app: redis-exporter # Метка для ServiceMonitor
spec:
  ports:
  - port: 9121
    targetPort: 9121
    name: metrics
  selector:
    app: redis-exporter

---
# Инструкция для Prometheus: "Считывай метрики отсюда"
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis-exporter
  namespace: monitoring
  labels:
    release: kube-prometheus-stack # ОБЯЗАТЕЛЬНО: чтобы Prometheus увидел этот монитор
spec:
  selector:
    matchLabels:
      app: redis-exporter
  endpoints:
  - port: metrics
    interval: 30s

---
# -------------------
# 2. POSTGRES EXPORTER
# -------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-exporter
  template:
    metadata:
      labels:
        app: postgres-exporter
    spec:
      containers:
      - name: postgres-exporter
        image: prometheuscommunity/postgres-exporter:v0.15.0
        env:
        - name: DATA_SOURCE_URI
          valueFrom: { secretKeyRef: { name: db-exporter-secrets, key: postgres-conn } }
        ports:
        - containerPort: 9187
          name: metrics

---
apiVersion: v1
kind: Service
metadata:
  name: postgres-exporter
  namespace: monitoring
  labels:
    app: postgres-exporter
spec:
  ports:
  - port: 9187
    targetPort: 9187
    name: metrics
  selector:
    app: postgres-exporter

---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postgres-exporter
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: postgres-exporter
  endpoints:
  - port: metrics
    interval: 30s

Примените:
code
Bash

kubectl apply -f db-exporters.yaml

Шаг 5. Мониторинг сертификатов (Cert-Manager)

Cert-manager уже имеет встроенные метрики, нам нужно просто "показать" их Прометеусу.
Создайте cert-manager-monitor.yaml:
code
Yaml

apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cert-manager
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - cert-manager # Namespace где стоит сам cert-manager
  selector:
    matchLabels:
      app: cert-manager
      app.kubernetes.io/component: controller
  endpoints:
  - port: tcp-prometheus-servicemonitor # Обычно этот порт открыт на сервисе cert-manager
    interval: 60s
    path: /metrics

Примените:
code
Bash

kubectl apply -f cert-manager-monitor.yaml

# Шаг 6. Настройка Grafana (Дашборды)

Теперь самое интересное.

Зайдите на https://grafana.ccsfarm.local (admin / admin).

Сразу увидите кучу встроенных дашбордов в папке Kubernetes (Node Exporter, Kubelet и т.д.).
Что нужно импортировать вручную (Кнопка "+" -> Import -> ID):
PostgreSQL: ID 9628 (один из лучших) или 12441.
Redis: ID 763 (классика для redis_exporter).
Cert-Manager: ID 11001 (покажет, сколько дней осталось до протухания сертификатов).
Nginx Ingress: ID 9614 (трафик, ошибки, latency).
Что мы получили в итоге:
Node Exporter: Показывает CPU/RAM/Disk всех 7 нод.
Kube-state-metrics: Показывает, если поды падают (CrashLoopBackOff) или PVC переполняются.
DB Exporters: Показывают внутренности Postgres и Redis (кол-во соединений, кэш-хиты).
Cert-Manager Monitor: Позволит настроить алерт "Сертификат истекает через 7 дней".
Если установка пройдет успешно, можно будет настроить Alertmanager, чтобы он слал уведомления в Telegram при падении подов или нехватке места.


# Prometheus
Это отличная мысль. Доступ к веб-интерфейсу Prometheus очень полезен для отладки: там можно проверять статус таргетов (Targets), смотреть, какие метрики приходят, и писать сырые PromQL запросы перед тем, как рисовать их в Grafana.
Так как мы устанавливали стек через Helm, сервис Prometheus уже создан, но он доступен только внутри кластера. Нам нужно создать для него Certificate (для HTTPS) и Ingress.
Шаг 1. Узнаем точное имя сервиса
Обычно при установке чарта kube-prometheus-stack сервис называется kube-prometheus-stack-prometheus. Но лучше проверить.
Выполните команду:
code
Bash
kubectl get svc -n monitoring | grep prometheus
Ищите сервис, который слушает порт 9090. Скорее всего, он называется kube-prometheus-stack-prometheus. Если имя отличается, поправьте его в манифесте ниже.
Шаг 2. Создаем манифест (prometheus-ingress.yaml)
Создайте файл prometheus-ingress.yaml. Этот манифест сделает две вещи:
Запросит сертификат у нашего CA для prom.ccsfarm.local.
Настроит Nginx Ingress на перенаправление трафика.
code
Yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: prometheus-tls
  namespace: monitoring
spec:
  secretName: prometheus-tls-secret
  dnsNames:
    - prom.ccsfarm.local
  issuerRef:
    name: ccsfarm-ca-issuer
    kind: ClusterIssuer
    group: cert-manager.io

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus-ingress
  namespace: monitoring
  annotations:
    # Опционально: увеличиваем размер тела запроса (иногда нужно для больших запросов API)
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - prom.ccsfarm.local
      secretName: prometheus-tls-secret
  rules:
    - host: prom.ccsfarm.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                # ⚠️ ПРОВЕРЬТЕ ИМЯ СЕРВИСА (см. Шаг 1)
                name: kube-prometheus-stack-prometheus
                port:
                  number: 9090
Шаг 3. Применяем и проверяем
Примените манифест:
code
Bash
kubectl apply -f prometheus-ingress.yaml
Подождите немного, пока cert-manager выпустит сертификат. Проверить статус можно командой:
code
Bash
kubectl get certificate -n monitoring prometheus-tls
(Должно быть READY: True)
Откройте в браузере:
https://prom.ccsfarm.local
🔐 Опционально: Добавляем пароль (Basic Auth)
Важный момент: У Prometheus "из коробки" нет авторизации. Если вы откроете его наружу, любой в вашей сети сможет зайти и смотреть метрики (или даже удалить их через API, если включен Admin API).
Хотя у вас закрытый периметр (VPN), хорошей практикой считается закрыть его хотя бы простым паролем через Nginx.
Как добавить Basic Auth:
Установите утилиту htpasswd (если нет):
sudo dnf install httpd-tools (для RED OS) или apt install apache2-utils.
Создайте файл с паролем:
code
Bash
# Создаем файл auth с пользователем admin
htpasswd -c auth admin
# (введите пароль)
Создайте секрет в Kubernetes:
code
Bash
kubectl create secret generic prometheus-basic-auth \
  --namespace monitoring \
  --from-file=auth
Обновите Ingress (prometheus-ingress.yaml):
Добавьте аннотации в секцию metadata:
code
Yaml
metadata:
  name: prometheus-ingress
  namespace: monitoring
  annotations:
    # --- Блок авторизации ---
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: prometheus-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: 'Authentication Required - Prometheus'
    # ------------------------
Примените изменения:
code
Bash
kubectl apply -f prometheus-ingress.yaml
Теперь при входе на prom.ccsfarm.local браузер спросит логин и пароль.


1. GitLab Runner
Раннер уже имеет встроенный HTTP-сервер метрик (порт 9252), нам нужно просто включить создание ServiceMonitor в его Helm-чарте.
Действия:
Откройте ваш values.yaml для gitlab-runner.
Найдите секцию metrics и приведите её к такому виду:
code
Yaml
metrics:
  enabled: true
  portName: metrics
  port: 9252
  serviceMonitor:
    enabled: true # Включаем создание монитора
    
    # ВАЖНО: Метка должна совпадать с именем релиза прометеуса
    # (по умолчанию это kube-prometheus-stack)
    labels:
      release: kube-prometheus-stack
    
    # Интервал сбора
    interval: "30s"
Примените изменения:
code
Bash
helm upgrade --install gitlab-runner gitlab/gitlab-runner -f values.yaml -n gitlab
2. MinIO (S3)
С MinIO чуть сложнее. По умолчанию метрики MinIO защищены токеном. Чтобы не возиться с генерацией JWT-токенов для Прометеуса, проще всего разрешить публичные метрики (это безопасно, так как доступ только внутри кластера).
Шаг А: Настройка MinIO (через ArgoCD/Manifest)
Вам нужно добавить переменную окружения в Deployment/StatefulSet вашего MinIO.
Переменная: MINIO_PROMETHEUS_AUTH_TYPE
Значение: "public"
Если вы используете Helm или ArgoCD, найдите секцию env и добавьте туда:
code
Yaml
env:
  - name: MINIO_PROMETHEUS_AUTH_TYPE
    value: "public"
После этого MinIO перезапустится.
Шаг Б: Создание ServiceMonitor
Теперь создадим манифест, который скажет Прометеусу забирать метрики.
Создайте файл minio-monitor.yaml:
code
Yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: minio-monitor
  namespace: monitoring # Кладем сам монитор в неймспейс мониторинга
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: minio # ⚠️ Убедитесь, что у сервиса MinIO есть этот лейбл (или app.kubernetes.io/name: minio)
  namespaceSelector:
    matchNames:
      - minio # Неймспейс, где стоит MinIO
  endpoints:
  - port: http # Имя порта сервиса (обычно http или service)
    path: /minio/v2/metrics/cluster
    interval: 30s
    scheme: http
Примечание: Проверьте kubectl get svc -n minio --show-labels, чтобы узнать точные лейблы (selector) и имя порта (port). Если порт называется 9000-tcp, пишите port: 9000-tcp.
Примените:
code
Bash
kubectl apply -f minio-monitor.yaml
3. GitLab (Omnibus/Server)
GitLab отдает огромное количество метрик (Rails, Sidekiq, Postgres-internal, Gitaly).
Создайте файл gitlab-monitor.yaml.
Этот монитор предполагает, что GitLab установлен в namespace gitlab.
code
Yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: gitlab-monitor
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: gitlab # Стандартный лейбл GitLab
  namespaceSelector:
    matchNames:
      - gitlab
  endpoints:
  # 1. Основные метрики GitLab (Rails/Unicorn/Puma)
  - port: http-webservice
    path: /-/metrics
    interval: 30s
    scheme: http
  
  # 2. Метрики Workhorse (обработка git-запросов)
  - port: http-workhorse
    path: /metrics
    interval: 30s
    scheme: http
  
  # 3. Метрики Sidekiq (очереди задач)
  # Обычно доступны на том же порту, что и веб-сервис, но иногда отдельно
  
  # 4. Gitaly (если он доступен как сервис)
  # Обычно требует отдельного ServiceMonitor, если Gitaly вынесен в отдельный под
Примените:
code
Bash
kubectl apply -f gitlab-monitor.yaml
⚠️ Нюанс с GitLab:
По умолчанию GitLab разрешает доступ к /-/metrics только из локальной сети. Если Prometheus не может получить данные (ошибка 403), вам нужно зайти в настройки GitLab (Admin Area -> Monitoring -> Metrics) и добавить CIDR подов Прометеуса (или 0.0.0.0/0 для теста) в "IP whitelist". Или настроить это через values.yaml GitLab'а (gitlab.webservice.monitoring.ipWhitelist).
4. Grafana Dashboards (Визуализация)
Теперь идем в Графану и импортируем дашборды (Import -> ID):
GitLab Runner: ID 11693 (Отличный дашборд: показывает кол-во активных джобов, ошибки, память).
MinIO: ID 13502 (Официальный дашборд для MinIO Cluster).
GitLab Overview: ID 5768 (Обзор здоровья GitLab).
Как проверить, что метрики идут?
Зайдите в интерфейс Prometheus (можно через Port Forward):
code
Bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
Откройте http://localhost:9090 -> Status -> Targets.
Вы должны увидеть разделы minio-monitor, gitlab-monitor и gitlab-runner.
Все они должны быть UP (зеленые). Если они DOWN, смотрите ошибку (обычно это либо "connection refused" — не тот порт, либо "403" — нет прав/вайтлиста).

Отлично, `curl` подтвердил доступность метрик (ошибка `Failure writing output` ожидаема, так как `head` закрыл поток раньше, чем `curl` закончил передачу).

Связь есть. Теперь реализуем механизм подключения в кластере.

Вот **готовые манифесты** для интеграции внешнего Proxmox хоста в ваш Prometheus Stack.

### 1. Механизм авто-сбора (ServiceMonitor)
Этот манифест нужно применить **один раз**. Он скажет Прометею: *"Следи за любыми сервисами, у которых есть лейбл `type: external-node`"*.

Файл: `1-monitor-config.yaml`
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: external-nodes-monitor
  namespace: monitoring  # Проверьте, что ваш Prometheus живет здесь
  labels:
    release: kube-prometheus-stack # Ключевой лейбл для обнаружения оператором
spec:
  selector:
    matchLabels:
      type: external-node # Мы будем вешать этот лейбл на новые ноды
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
    # Увеличим таймаут, так как внешняя сеть может быть медленнее
    scrapeTimeout: 10s
  namespaceSelector:
    matchNames:
    - monitoring
```

### 2. Подключение хоста Proxmox (Service + Endpoints)
Этот манифест — и есть тот самый **"Механизм добавления новых нод"**.
Чтобы добавить новую железку в будущем, вы просто копируете этот файл, меняете `name` и `ip`.

Файл: `2-node-proxmox.yaml`
```yaml
# 1. Объявляем сервис (Интерфейс)
apiVersion: v1
kind: Service
metadata:
  name: node-proxmox-chia04  # Имя хоста (для удобства)
  namespace: monitoring
  labels:
    type: external-node      # <-- Этот лейбл зацепит ServiceMonitor
    app: node-exporter
spec:
  ports:
  - name: metrics
    port: 9100
    protocol: TCP
    targetPort: 9100
  type: ClusterIP
---
# 2. Указываем куда стучаться (Реализация)
apiVersion: v1
kind: Endpoints
metadata:
  name: node-proxmox-chia04  # Должно СТРОГО совпадать с именем Service
  namespace: monitoring
  labels:
    type: external-node
subsets:
- addresses:
  - ip: 10.10.1.54           # <-- Ваш реальный IP Proxmox
  ports:
  - name: metrics
    port: 9100
    protocol: TCP
```

### 3. Алерты (PrometheusRule)
Базовый набор правил для внешних серверов.

Файл: `3-node-alerts.yaml`
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: external-nodes-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: external-nodes.rules
    rules:
    # 1. Хост лежит
    - alert: ExternalHostDown
      expr: up{job="node-proxmox-chia04"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Proxmox Host {{ $labels.instance }} is DOWN"
        description: "Node Exporter недоступен более 2 минут."

    # 2. Высокая нагрузка CPU (> 90%)
    - alert: ExternalHostHighCpu
      expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "High CPU load on {{ $labels.instance }}"

    # 3. Заканчивается место на диске (< 10%)
    - alert: ExternalHostLowDisk
      expr: (node_filesystem_avail_bytes{fstype!=""} / node_filesystem_size_bytes{fstype!=""}) * 100 < 10
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "Low Disk Space on {{ $labels.instance }}"
```

### Как применить:

```bash
kubectl apply -f 1-monitor-config.yaml
kubectl apply -f 2-node-proxmox.yaml
kubectl apply -f 3-node-alerts.yaml
```

### 4. Визуализация в Grafana

1.  Откройте Grafana.
2.  **Dashboards** -> **New** -> **Import**.
3.  Введите ID: **1860** (Node Exporter Full). Это золотой стандарт.
4.  Нажмите **Load**.
5.  Выберите ваш Prometheus datasource.
6.  После импорта, в фильтре "Job" или "Host" вы увидите IP вашего Proxmox (`10.10.1.54`).

Теперь ваш гипервизор под полным контролем.