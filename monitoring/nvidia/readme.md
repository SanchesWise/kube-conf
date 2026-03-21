helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

helm install dcgm-exporter nvidia/dcgm-exporter \
  -f gpu-monitoring-values.yaml \
  -n monitoring

Ниже приведена полная техническая инструкция по вводу в эксплуатацию новой GPU-ноды в кластере `ccsfarm.local` и деплою типового приложения. 

---

# Регламент настройки GPU-инфраструктуры в кластере `ccsfarm.local`

Данная инструкция описывает процесс настройки сквозного проброса (PCI Passthrough) видеокарт в среду Kubernetes с использованием рантайма **CRI-O** на ОС семейства **RedOS/RHEL**.

## Часть 1: Подготовка ОС на новой ноде (Воркер)

Предположим, новая нода — `k8s-gpu-worker03.ccsfarm.local`.

### 1.1. Установка драйверов NVIDIA
На ноде должны быть установлены `kernel-devel`, соответствующий версии ядра, и официальный драйвер NVIDIA.

```bash
# Проверка наличия видеокарт на шине PCI
lspci | grep –i nvidia

# Проверка работоспособности драйвера
nvidia-smi
```

### 1.2. Установка NVIDIA Container Toolkit
Для работы CRI-O необходимо установить инструментарий, который позволит рантайму взаимодействовать с драйвером хоста.

```bash
# Добавление репозитория и установка
sudo dnf install -y nvidia-container-toolkit
```

### 1.3. Настройка рантайма CRI-O
CRI-O должен знать о существовании обработчика `nvidia`. 

1. Создайте файл конфигурации рантайма:
```bash
sudo vim /etc/crio/crio.conf.d/99-nvidia.conf
```
Вставьте следующее (строго соблюдая синтаксис):
```ini
[crio.runtime.runtimes.nvidia]
runtime_path = "/usr/bin/nvidia-container-runtime"
runtime_type = "oci"
```

2. Исправьте путь к базовому рантайму (`runc`) в конфигурации NVIDIA:
```bash
sudo vim /etc/nvidia-container-runtime/config.toml
```
Найдите и измените параметр `path`:
```ini
[nvidia-container-runtime]
path = "/usr/bin/runc"
```

3. Перезапустите службу:
```bash
sudo systemctl restart crio
```

---

## Часть 2: Настройка Kubernetes (Мастер-нода)

### 2.1. Создание RuntimeClass
Чтобы поды понимали, какой обработчик использовать, в кластере должен существовать `RuntimeClass`. (Делается один раз на весь кластер).

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
`kubectl apply -f nvidia-runtime-class.yaml`

### 2.2. Установка NVIDIA Device Plugin
Это сервис, который сканирует видеокарты на нодах и сообщает их количество планировщику Kubernetes.

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm upgrade --install nvdp nvdp/k8s-device-plugin \
  --namespace kube-system \
  --set runtimeClassName=nvidia
```

### 2.3. Маркировка ноды
Пометьте новую ноду, чтобы мониторинг и планировщик видели её:
```bash
kubectl label node k8s-gpu-worker03.ccsfarm.local nvidia.com/gpu.present=true
```

---

## Часть 3: Шаблон типового пода приложения

Для запуска приложения, использующего GPU (например, PyTorch или TensorFlow), используйте следующий шаблон манифеста.

```bash
vim gpu-app-template.yaml
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-app-example
  namespace: default
spec:
  # 1. Обязательно указываем созданный RuntimeClass
  runtimeClassName: nvidia
  
  nodeSelector:
    # 2. Гарантируем запуск на GPU-ноде
    nvidia.com/gpu.present: "true"

  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "gpu"
    operator: "Equal"
    value: "low-performance" #high для 3090
    effect: "NoSchedule"    

  containers:
  - name: cuda-container
    image: nvidia/cuda:12.2.0-runtime-ubuntu22.04
    command: ["sh", "-c", "nvidia-smi && sleep 3600"]
    
    # 3. Переменные для активации библиотек внутри контейнера
    env:
    - name: NVIDIA_VISIBLE_DEVICES
      value: "all"
    - name: NVIDIA_DRIVER_CAPABILITIES
      value: "compute,utility,video"
    # Для RedOS/RHEL обязательно добавляем пути к библиотекам драйвера
    - name: LD_LIBRARY_PATH
      value: "/usr/lib64:/usr/local/nvidia/lib64"

    # 4. Запрос ресурсов GPU (планировщик выделит конкретную карту)
    resources:
      limits:
        nvidia.com/gpu: 1 # Запрашиваем 1 видеокарту
```

---

## Часть 4: Диагностика внутри пода

Поскольку в рабочих образах часто нет диагностических утилит, используйте эти методы для проверки проброса GPU.

### 4.1. Проверка устройств
Если драйвер проброшен корректно, в `/dev` должны появиться файлы устройств:
```bash
kubectl exec -it gpu-app-example -- ls -l /dev/nvidia0
```

### 4.2. Проверка библиотек
Убедитесь, что библиотеки драйвера доступны в путях поиска:
```bash
kubectl exec -it gpu-app-example -- ls -l /usr/lib64/libnvidia-ml.so.1
```

### 4.3. Проверка переменных окружения
```bash
kubectl exec -it gpu-app-example -- env | grep NVIDIA
```

---

## Часть 5: Мониторинг и Алертинг (Alertmanager)

Для каждой новой GPU-ноды автоматически начнут собираться метрики через `dcgm-exporter`.

### Критические показатели для контроля:
1. **DCGM_FI_DEV_GPU_TEMP**: Температура ядра. Для P104-100 порог алертинга **85°C**.
2. **DCGM_FI_DEV_MEMORY_TEMP**: Температура памяти (GDDR6X). Для RTX 3090 критический порог **104°C**.
3. **DCGM_FI_DEV_XID_ERRORS**: Если значение `> 0`, значит произошел аппаратный сбой или отвал видеокарты с шины PCI-E. 

**При получении алерта GpuXidError:** необходимо проверить `dmesg` на воркер-ноде и, в случае "отвала" карты, перезагрузить физическую ноду `gpu-prox.ccsfarm.local`.