Шаг 2. Установка NATS JetStream



Теперь, когда у нас есть быстрый блочный диск, разворачиваем NATS.

# Добавляем репо
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update

# Создай файл k8s/nats-values.yaml:

code Yaml

    
config:
  cluster:
    enabled: true
    replicas: 3
  jetstream:
    enabled: true
    fileStore:
      pvc:
        enabled: true
        size: 10Gi
        # Явно указываем longhorn, хотя он и так теперь дефолтный
        storageClassName: "longhorn" 
    memoryStore:
      enabled: true
      maxSize: 1Gi

# Сервис для доступа внутри кластера
service:
  enabled: true

# Мониторинг
promExporter:
  enabled: true
  podMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack

  

    Установи чарт:

code Bash

    
# Создаем неймспейс, если нет
kubectl create namespace nats

# Установка
helm install nats nats/nats -f k8s/nats-values.yaml -n nats

  

    Проверь статус:

code Bash

    
kubectl get pods -n nats
kubectl get pvc -n nats

  