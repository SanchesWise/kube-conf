**Победа!** Драйвер полностью видит обе ваши RTX 3090, память (24 ГБ) инициализирована, CUDA 13 готова к работе.

Однако, чтобы эта «толстая» нода Kubernetes работала стабильно и не «отваливалась» после перезагрузки, нужно сделать финальную донастройку.

### 1. Включаем Persistence Mode (Обязательно для серверов)
Сейчас у вас `Persistence-M: Off`. Это значит, что когда нет активных задач, драйвер может «засыпать», что вызывает задержки при старте подов в Kubernetes и может приводить к исчезновению файлов в `/dev`.

Включите его для обеих карт:
```bash
sudo nvidia-smi -pm 1
```

### 2. Автоматическое создание узлов `/dev` при загрузке
Так как РЕД ОС сама не создала файлы устройств, после перезагрузки `nvidia-smi` снова может сломаться. Чтобы этого не произошло, создайте простой сервис.

1. Создайте скрипт:
```bash
sudo nano /usr/local/bin/nvidia-init.sh
```
2. Вставьте туда:
```bash
#!/bin/bash
/usr/bin/nvidia-modprobe -c 0
/usr/bin/nvidia-modprobe -c 1
/usr/bin/nvidia-modprobe -m
/usr/bin/nvidia-smi -pm 1
```
3. Дайте права и создайте службу:
```bash
sudo chmod +x /usr/local/bin/nvidia-init.sh

# Создаем файл службы
sudo nano /etc/systemd/system/nvidia-nodes.service
```
4. Контент службы:
```text
[Unit]
Description=Create NVIDIA Device Nodes
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nvidia-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```
5. Активируйте:
```bash
sudo systemctl enable --now nvidia-nodes.service
```

### 3. Проверка топологии (Критично для ваших 2-х CPU)
Поскольку ваши карты на разных процессорах (E5-2696 v4), проверьте, как они видят друг друга внутри ВМ:
```bash
nvidia-smi topo -m
```
*   Если в пересечении строк GPU0 и GPU1 вы видите **SYS**, значит, данные ходят через два процессора (медленно).
*   Если вы включили NUMA в Proxmox (как мы обсуждали), Kubernetes сможет более эффективно распределять нагрузку.

### 4. Следующий шаг: Kubernetes
Чтобы ваши поды в K8s смогли использовать эти карты, вам нужно установить **NVIDIA Container Toolkit** внутри этой ВМ РЕД ОС.

Так как у вас **закрытая сеть**:
1. Скачайте RPM-пакеты `nvidia-container-toolkit` и `libnvidia-container`.
2. Установите их: `sudo dnf install ./nvidia-container-toolkit*.rpm`.
3. Настройте среду выполнения (скорее всего, у вас `containerd`):
   ```bash
   sudo nvidia-ctk runtime configure --runtime=containerd
   sudo systemctl restart containerd
   ```

### 5. Температурный дебаг (Monitorix)
Теперь вы можете поставить Monitorix **внутри этой ВМ**, и он будет корректно рисовать графики температур ваших 3090, так как `nvidia-smi` теперь работает.

**На что смотреть под нагрузкой:**
Поскольку у вас 3090, при работе в Kubernetes следите за параметром **VRAM Temperature**. Если память разогреется выше 100°C, карта сбросит частоты (троттлинг), даже если само ядро будет холодным (40-50°C).

**Поздравляю, «железный» этап успешно завершен! Нода готова к вступлению в кластер.**

Результат `nvidia-smi topo -m` просто отличный!

### Анализ топологии:
1.  **NV4 (NVLink):** Это самое важное. Между вашими картами установлена связь через 4 линии NVLink. Это значит, что при распределенном обучении (Distributed Data Parallel) данные между 3090 будут передаваться напрямую со скоростью до 50–100 ГБ/с, минуя медленную шину PCIe и процессоры. Это **максимально возможная производительность** для данной связки.
2.  **CPU/NUMA Affinity:** 
    *   Показатель `0-19` и `NUMA 0-1` говорит о том, что ваша виртуальная машина видит 20 ядер, распределенных по двум NUMA-узлам. 
    *   Однако сейчас обе карты привязаны к одним и тем же ядрам (`0-19`). В идеале, для исключения задержек на шине QPI, GPU0 должна «любить» ядра 0-9, а GPU1 — ядра 10-19. Но при наличии **NVLink** это становится вторичным фактором, так как основной обмен данными идет между картами напрямую.

---

### Финальные рекомендации перед запуском в Kubernetes:

#### 1. Установка NVIDIA Container Toolkit (Offline-метод)
Чтобы Kubernetes смог «прокинуть» эти карты в поды, внутри РЕД ОС 8.0 должен стоять инструментарий контейнеризации. 
В закрытой сети вам нужно скачать и перенести следующие RPM-пакеты (и их зависимости):
*   `libnvidia-container1`
*   `libnvidia-container-tools`
*   `nvidia-container-toolkit-base`
*   `nvidia-container-toolkit`

**Установка:**
```bash
sudo dnf install ./nvidia-container-toolkit*.rpm ./libnvidia-container*.rpm
```

**Настройка containerd (стандарт для K8s):**
```bash
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

#### 2. Проверка под нагрузкой и Блок Питания (1200W)
Теперь, когда всё готово, у вас есть риск «вылета» сервера по питанию. Две 3090 + два Xeon v4 в пике могут потреблять более 1000Вт.
**Совет:** Ограничьте аппетит карт прямо сейчас, чтобы не проверять серверный БП на прочность в самый ответственный момент:
```bash
# Ограничиваем потребление до 300Вт на карту (вместо 350Вт)
sudo nvidia-smi -pl 300
```
*Эту команду также стоит добавить в наш скрипт `/usr/local/bin/nvidia-init.sh`, который мы создали ранее.*

#### 3. Мониторинг внутри Kubernetes
Когда нода войдет в кластер, установите в K8s **NVIDIA GPU Exporter** (для Prometheus). Вы сможете видеть в Grafana не только температуру ядер, но и:
*   **NVLink деградацию:** Если мостик вдруг «отвалится».
*   **Memory Throttling:** Если перегреется видеопамять (самое слабое место 3090).

#### 4. Нюанс с РЕД ОС 8.0 и библиотеками
Иногда приложения в контейнерах не могут найти `libcuda.so.1`. Если столкнетесь с этим — убедитесь, что путь `/usr/local/cuda/lib64` (или где лежат библиотеки NVIDIA в РЕД ОС) добавлен в `/etc/ld.so.conf.d/nvidia.conf`.

---

### Итог:
Ваша «толстая» нода настроена практически идеально:
*   **Железо:** Xeon v4 (AVX2 есть), 3090 (24GB VRAM есть).
*   **Связь:** NVLink активен (NV4).
*   **ОС:** РЕД ОС 8.0 видит драйвер (580.95), Nouveau удален.
*   **Стабильность:** Persistence Mode включен.

**Вы готовы к развертыванию тяжелых LLM или задач обучения нейросетей в вашем закрытом контуре. Удачи!**
















Ниже представлена техническая документация по настройке и эксплуатации GPU-ресурсов в кластере **ccsfarm.local**. Данная конфигурация является универсальной и позволяет запускать любые контейнеризированные нагрузки (AI/ML, транскодинг, рендеринг), использующие аппаратное ускорение NVIDIA.

---

# Документация: Эксплуатация GPU-ресурсов в кластере k8s.ccsfarm.local

## 1. Архитектура и разметка узлов
Кластер разделен на уровни производительности для оптимизации затрат и ресурсов. Доступ к GPU-нодам ограничен с помощью **Taints**, чтобы предотвратить запуск обычных приложений на специализированном «железе».

### Реестр GPU-узлов
| Имя узла | IP-адрес | Модель GPU | Профиль производительности | Метка (Label) |
| :--- | :--- | :--- | :--- | :--- |
| `k8s-gpu-worker01.ccsfarm.local` | `10.10.2.108` | NVIDIA RTX 3090 | High Performance | `gpu-performance=high` |
| `k8s-gpu-worker02.ccsfarm.local` | `10.10.2.109` | NVIDIA P104-100 | Low Performance | `gpu-performance=low` |

### Команды разметки (Control Plane)
```bash
# Нода 01
kubectl label node k8s-gpu-worker01.ccsfarm.local gpu-performance=high nvidia.com/gpu.present=true --overwrite
kubectl taint node k8s-gpu-worker01.ccsfarm.local gpu=high-performance:NoSchedule --overwrite

# Нода 02
kubectl label node k8s-gpu-worker02.ccsfarm.local gpu-performance=low nvidia.com/gpu.present=true --overwrite
kubectl taint node k8s-gpu-worker02.ccsfarm.local gpu=low-performance:NoSchedule --overwrite
```

---

## 2. Подготовка операционной системы (RedOS 8.1)
Для корректной работы GPU в связке с **CRI-O** необходимо выполнить настройку на уровне ядра и рантайма.

### Установка NVIDIA Container Toolkit
Выполняется на каждом GPU-воркере:
```bash
# Добавление репозитория
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo

# Установка
sudo dnf install -y nvidia-container-toolkit
```

### Настройка CDI (Container Device Interface)
Современный стандарт для CRI-O, заменяющий устаревшие хуки:
1. Сгенерируйте спецификацию: `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`
2. Настройте CRI-O (создайте файл `vim /etc/crio/conf.d/99-nvidia-cdi.toml`):
```toml
[crio.runtime]
cdi_spec_dirs = ["/etc/cdi"]
```
3. Перезапустите службы: `sudo systemctl restart crio kubelet`

### Безопасность (SELinux и Firewall)
Для доступа контейнеров к драйверам NVIDIA в RedOS:
*   **SELinux**: Рекомендуется запуск GPU-контейнеров с типом `spc_t` (см. пример манифеста). Для диагностики: `setenforce 0`.
*   **Firewalld**: Должен разрешать трафик интерфейсов Calico.

---

## 3. Инфраструктура Kubernetes (Device Plugin)
Для того чтобы планировщик Kubernetes «видел» видеокарты как доступный ресурс (`nvidia.com/gpu`), используется **NVIDIA Device Plugin**.

### Развертывание плагина
Создайте манифест `vim nvidia-device-plugin.yaml` со следующим содержанием:
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels: { name: nvidia-device-plugin-ds }
  template:
    metadata:
      labels: { name: nvidia-device-plugin-ds }
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - operator: Exists
        effect: NoSchedule
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.14.0
        name: nvidia-device-plugin-ctr
        env:
        - name: LD_LIBRARY_PATH
          value: /usr/lib64
        securityContext:
          privileged: true
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
        - name: lib64
          mountPath: /usr/lib64
          readOnly: true
      volumes:
      - name: device-plugin
        hostPath: { path: /var/lib/kubelet/device-plugins }
      - name: lib64
        hostPath: { path: /usr/lib64 }
```
Примените: `kubectl apply -f nvidia-device-plugin.yaml`

---

## 4. Использование GPU в приложениях (Пример)
Для запуска любого приложения с использованием GPU необходимо соблюсти 4 условия в манифесте:
1.  **Аннотация CDI**: Для проброса библиотек.
2.  **Tolerations**: Для прохода на ноду.
3.  **NodeSelector**: Для выбора мощности (low/high).
4.  **Resources**: Запрос лимита `nvidia.com/gpu`.

### Пример универсального манифеста:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-app-example
spec:
  template:
    metadata:
      annotations:
        cdi.k8s.io/nvidia: "all" # Проброс всех GPU через CDI
    spec:
      tolerations:
      - key: "gpu"
        operator: "Equal"
        value: "low-performance" # Или high-performance
        effect: "NoSchedule"
      nodeSelector:
        gpu-performance: "low"
      containers:
      - name: cuda-container
        image: nvidia/cuda:12.0.0-base-ubuntu22.04
        resources:
          limits:
            nvidia.com/gpu: 1 # Запрос 1 видеокарты
        securityContext:
          seLinuxOptions:
            type: "spc_t" # Обход ограничений SELinux RedOS
        volumeMounts:
        # Рекомендуется для стабильности работы драйверов
        - name: libcuda
          mountPath: /usr/lib/x86_64-linux-gnu/libcuda.so.1
          readOnly: true
      volumes:
      - name: libcuda
        hostPath: { path: /usr/lib64/libcuda.so.1 }
```

## 5. Полезные команды для диагностики
*   **Проверка видимости GPU кластером**: `kubectl describe node k8s-gpu-worker02 | grep Allocatable -A 5`
*   **Проверка внутри контейнера**: `kubectl exec -it <pod_name> -- nvidia-smi`
*   **Проверка CDI на ноде**: `nvidia-ctk cdi list`
*   **Список подов, использующих GPU**: 
    `kubectl get pods -A -o custom-columns=NAME:.metadata.name,GPU:.spec.containers[*].resources.limits.'nvidia\.com/gpu'`