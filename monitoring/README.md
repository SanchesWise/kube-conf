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

Шаг 6. Настройка Grafana (Дашборды)

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