займемся "глазами и ушами" кластера. Для Kubernetes де-факто стандартом является **Prometheus Operator** (сейчас он называется `kube-prometheus-stack`). Это "комбайн", который устанавливает Prometheus, Grafana, Alertmanager и кучу стандартных экспортеров одной командой.

Учитывая, что у вас 2025 год и Red OS, будем использовать **Helm** — это самый надежный способ управления таким сложным стеком.

### 📋 Что будем ставить

1.  **kube-prometheus-stack** (База):
    *   **Prometheus:** Сбор метрик.
    *   **Grafana:** Визуализация.
    *   **Node Exporter:** Состояние железа (CPU, RAM, Диск, Сеть) на всех 7 нодах.
    *   **Kube-State-Metrics:** Состояние объектов K8s (сколько подов упало, статусы деплойментов).
    *   **Kubelet / cAdvisor:** Потребление ресурсов конкретными контейнерами.
2.  **Дополнительные Экспортеры** (То, чего нет в базовом стеке):
    *   **Postgres Exporter:** Для вашей внешней базы данных.
    *   **Redis Exporter:** Для Redis.
    *   **Blackbox Exporter** (Опционально): Для проверки "отвечает ли сайт" и "когда протухнет сертификат".
    *   **Cert-Manager ServiceMonitor:** Для мониторинга выпуска сертификатов.

---

### Шаг 1. Подготовка конфигурации (`values.yaml`)

Создайте файл `monitoring-values.yaml`. Я адаптировал его под вашу архитектуру (NFS, Ingress, CA).

```yaml
# monitoring-values.yaml

# 1. Настройки Grafana
grafana:
  adminPassword: "admin" # ⚠️ Смените при первом входе!
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - grafana.ccsfarm.local
    tls:
      - secretName: grafana-tls-secret
        hosts:
          - grafana.ccsfarm.local
  persistence:
    enabled: true
    storageClassName: managed-nfs-storage
    size: 10Gi
  # Автоматическое добавление дашбордов для Nginx Ingress и Cert-Manager
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

# 2. Настройки Prometheus
prometheus:
  prometheusSpec:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: managed-nfs-storage
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    # Сколько хранить метрики (по умолчанию 10 дней, ставим 30)
    retention: 30d
    # Разрешаем мониторить сервисы в других namespaces (важно для DB)
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    serviceMonitorNamespaceSelector: {}

# 3. Alertmanager (для уведомлений в Telegram/Email)
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

# 4. Мониторинг компонентов K8s
kubeControllerManager:
  enabled: true
kubeEtcd:
  enabled: true
kubeScheduler:
  enabled: true
coreDns:
  enabled: true # Мониторинг DNS
```

### Шаг 2. Установка стека через Helm

Если Helm еще не установлен на управляющей машине:
*(Для RED OS)* `sudo dnf install helm` или скачать бинарник.

1.  **Добавляем репозиторий:**
    ```bash
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    ```

2.  **Создаем сертификаты для Grafana и Alertmanager:**
    Вам нужно создать `Certificate` ресурсы для `grafana.ccsfarm.local` и `alertmanager.ccsfarm.local` (по аналогии с прошлым шагом), чтобы Ingress подхватил HTTPS.

3.  **Устанавливаем в namespace `monitoring`:**
    ```bash
    kubectl create namespace monitoring
    
    helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
      -n monitoring \
      -f monitoring-values.yaml
    ```

---

### Шаг 3. Мониторинг Баз Данных (Postgres & Redis)

Так как ваши базы данных находятся вне стека мониторинга (в отдельных неймспейсах), нам нужно запустить к ним **экспортеры** (агенты, которые заходят в базу, берут цифры и отдают Прометеусу).

Создайте файл `db-exporters.yaml`.
*Вам понадобится узнать пароли от Postgres и Redis.*

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-exporter-secrets
  namespace: monitoring
type: Opaque
stringData:
  # УКАЖИТЕ РЕАЛЬНЫЕ ДАННЫЕ ПОДКЛЮЧЕНИЯ
  redis-addr: "redis.redis.svc.cluster.local:6379"
  redis-password: "YOUR_REDIS_PASSWORD" 
  postgres-conn: "postgresql://postgres:PASSWORD@postgres-np.postgres.svc.cluster.local:5432/postgres?sslmode=disable"

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
          valueFrom:
            secretKeyRef:
              name: db-exporter-secrets
              key: redis-addr
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-exporter-secrets
              key: redis-password
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
    app: redis-exporter
spec:
  ports:
  - port: 9121
    targetPort: 9121
    name: metrics
  selector:
    app: redis-exporter

---
# Сообщаем Прометеусу, что нужно читать этот сервис
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis-exporter
  namespace: monitoring
  labels:
    release: kube-prometheus-stack # ВАЖНО: Чтобы прометеус увидел конфиг
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
          valueFrom:
            secretKeyRef:
              name: db-exporter-secrets
              key: postgres-conn
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
```

Примените манифест:
```bash
kubectl apply -f db-exporters.yaml
```

---

### Шаг 4. Мониторинг Cert-Manager

Cert-manager уже имеет встроенные метрики, нам нужно только создать `ServiceMonitor`, чтобы Prometheus начал их собирать.

Создайте файл `cert-manager-monitor.yaml`:

```yaml
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
      - cert-manager # Namespace, где стоит cert-manager
  selector:
    matchLabels:
      app: cert-manager
      app.kubernetes.io/component: controller
  endpoints:
  - port: tcp-prometheus-servicemonitor
    interval: 60s
    path: /metrics
```

Примените:
```bash
kubectl apply -f cert-manager-monitor.yaml
```

---

### Шаг 5. Настройка Grafana (Дашборды)

После установки зайдите в `https://grafana.ccsfarm.local` (по умолчанию admin/admin или тот пароль, что вы задали в values.yaml).

В стеке **уже** будут предустановлены дашборды:
1.  **Kubernetes / Compute Resources / Cluster** — общая загрузка.
2.  **Kubernetes / Compute Resources / Node (Pods)** — детально по нодам.
3.  **Node Exporter / Nodes** — состояние "железа" (диск, сеть).

**Рекомендуемые ID дашбордов для импорта (Import -> ID):**

*   **PostgreSQL:** ID `9628` (PostgreSQL Database) — показывает коннекты, транзакции, локи.
*   **Redis:** ID `763` (Redis Dashboard for Prometheus Redis Exporter).
*   **NGINX Ingress:** ID `9614` (NGINX Ingress controller).
*   **Cert-Manager:** ID `11001` (Cert-Manager) — показывает, когда истекают сертификаты.

### Резюме по вашим запросам:

1.  **Состояние подов/нод/ресурсы:** Покрыто `kube-prometheus-stack` (Node Exporter + cAdvisor).
2.  **DNS:** Покрыто `coreDns` конфигом в values.yaml.
3.  **Сертификаты:** Покрыто ServiceMonitor для Cert-Manager + дашборд 11001.
4.  **Дисковое пространство:**
    *   Место на нодах (root/mounts): Node Exporter.
    *   Место в PVC: Kubelet metrics (встроено в стек).
5.  **Базы данных:** Покрыто деплойментами экспортеров (`db-exporters.yaml`).