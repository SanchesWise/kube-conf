Настоящая документация описывает процесс ввода в эксплуатацию новой GPU-ноды в кластере `ccsfarm.local` и правила развертывания приложений, использующих аппаратное ускорение.

---

# Часть 1: Подготовка новой ноды (Infrastructure Layer)

Предполагается, что нода развернута как виртуальная машина на Proxmox (`gpu-prox.ccsfarm.local`) с использованием **PCI Passthrough** видеокарт.

### 1.1. Настройка ОС (RedOS / RHEL-family)
На новой ноде (например, `k8s-gpu-worker03.ccsfarm.local`) должны быть установлены драйверы NVIDIA и `nvidia-container-toolkit`.

```bash
# Проверка наличия устройств в системе
lspci | grep -i nvidia

# Проверка работоспособности драйвера
nvidia-smi
```

### 1.2. Настройка CRI-O для работы с NVIDIA
Для того чтобы CRI-O мог использовать видеокарты, необходимо создать специфичный рантайм-хендлер.

1. Создайте файл конфигурации через `vim`:
```bash
sudo vim /etc/crio/crio.conf.d/99-nvidia.conf
```
Вставьте следующее содержимое:
```ini
[crio.runtime.runtimes.nvidia]
runtime_path = "/usr/bin/nvidia-container-runtime"
runtime_type = "oci"
```

2. Перезапустите CRI-O и проверьте, что рантайм подгрузился:
```bash
sudo systemctl restart crio
sudo crio config | grep nvidia
```

---

# Часть 2: Интеграция с Kubernetes (Cluster Layer)

### 2.1. Создание RuntimeClass
Если это не было сделано ранее, создайте общекластерный ресурс, который связывает манифесты подов с хендлером CRI-O.

```bash
vim nvidia-runtime-class.yaml
```
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
```
```bash
kubectl apply -f nvidia-runtime-class.yaml
```

### 2.2. Разметка нод (Labels & Taints)
Для разделения нагрузок (P104 vs 3090) мы используем метки производительности и запреты (Taints), чтобы обычные поды не занимали GPU-ноды.

**Для ноды с RTX 3090 (High Performance):**
```bash
# Метка для селектора
kubectl label node k8s-gpu-worker01.ccsfarm.local gpu=high-performance
# Запрет для обычных подов
kubectl taint nodes k8s-gpu-worker01.ccsfarm.local gpu=high-performance:NoSchedule
```

**Для ноды с P104-100 (Low Performance):**
```bash
# Метка для селектора
kubectl label node k8s-gpu-worker02.ccsfarm.local gpu=low-performance
# Запрет для обычных подов
kubectl taint nodes k8s-gpu-worker02.ccsfarm.local gpu=low-performance:NoSchedule
```

---

# Часть 3: Настройка типового пода приложения (Application Layer)

Для запуска приложения на GPU в нашем кластере, манифест должен содержать 3 обязательных компонента: **RuntimeClass**, **Tolerations** (допуски) и **NodeSelector**.

### 3.1. Пример манифеста (Тяжелая модель на RTX 3090)

Создайте файл `gpu-app-high.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-high-perf-app
  namespace: default
spec:
  # 1. Используем настроенный рантайм NVIDIA
  runtimeClassName: nvidia
  
  # 2. Направляем под на ноду с RTX 3090
  nodeSelector:
    gpu: "high-performance"
  
  # 3. Разрешаем запуск на ноде с Taint
  tolerations:
  - key: "gpu"
    operator: "Equal"
    value: "high-performance"
    effect: "NoSchedule"

  containers:
  - name: cuda-container
    image: nvidia/cuda:12.2.0-runtime-ubuntu22.04
    command: ["sh", "-c", "nvidia-smi && sleep 3600"]
    # 4. Переменные для активации проброса внутри CRI-O
    env:
    - name: NVIDIA_VISIBLE_DEVICES
      value: "all"
    - name: NVIDIA_DRIVER_CAPABILITIES
      value: "compute,utility"
    resources:
      limits:
        nvidia.com/gpu: 1 # Запрос 1 видеокарты
```

### 3.2. Пример манифеста (Легкая нагрузка на P104-100)

Создайте файл `gpu-app-low.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cuda-low-perf-app
spec:
  runtimeClassName: nvidia
  nodeSelector:
    gpu: "low-performance"
  tolerations:
  - key: "gpu"
    operator: "Equal"
    value: "low-performance"
    effect: "NoSchedule"
  containers:
  - name: cuda-container
    image: nvidia/cuda:12.2.0-runtime-ubuntu22.04
    command: ["sh", "-c", "nvidia-smi && sleep 3600"]
    env:
    - name: NVIDIA_VISIBLE_DEVICES
      value: "all"
    - name: NVIDIA_DRIVER_CAPABILITIES
      value: "compute,utility"
    resources:
      limits:
        nvidia.com/gpu: 1
```

---

# Часть 4: Диагностика внутри пода

В наших образах отсутствуют расширенные утилиты диагностики, поэтому используйте базовые системные методы проверки проброса.

1. **Проверка устройств:**
```bash
kubectl exec -it <pod-name> -- ls -l /dev/nvidia*
# Ожидаемый результат: наличие /dev/nvidia0, /dev/nvidiactl и т.д.
```

2. **Проверка библиотек (внутри пода):**
Если приложение не видит GPU, проверьте, пробросил ли их CRI-O в системные пути:
```bash
kubectl exec -it <pod-name> -- ldconfig -p | grep nvidia
# На RedOS/UBI образах проверьте:
kubectl exec -it <pod-name> -- ls /usr/lib64 | grep libnvidia
```

3. **Логи рантайма на хосте:**
Если под висит в `ContainerCreating`, проверьте логи CRI-O на соответствующем воркере:
```bash
sudo journalctl -u crio -n 50 --no-pager
```

---
**Документация актуальна для кластера `ccsfarm.local` на дату 22.03.2026.**