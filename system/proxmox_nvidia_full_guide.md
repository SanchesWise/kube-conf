# Полный Гайд: Установка NVIDIA Драйверов на Proxmox 8.4

## Оглавление
1. Проверка наличия видеокарты
2. Диагностика проблемы репозиториев
3. Исправление репозиториев
4. Установка зависимостей
5. Установка NVIDIA драйверов
6. Проверка установки
7. Решение проблем
8. Использование GPU для VM (passthrough)
9. Мониторинг и диагностика

---

## 1. ПРОВЕРКА НАЛИЧИЯ ВИДЕОКАРТЫ

### Команда 1.1: Базовое Обнаружение

```bash
lspci | grep -i nvidia
```

**Результат должен содержать строку вроде:**
```
01:00.0 VGA compatible controller: NVIDIA Corporation GP104 [GeForce GTX 1070]
```

Если ничего не выводит — видеокарта не обнаружена или отключена в BIOS.

### Команда 1.2: Детальная Информация

```bash
lspci -v | grep -A 10 "VGA"
```

**Важные параметры для записи:**
- **Bus ID**: 01:00.0 (нужен для passthrough)
- **Kernel driver in use**: посмотри что сейчас загружено (может быть пусто, nouveau, nvidia)
- **Vendor ID / Device ID**: (например, 10de:1b81 для GTX 1070)

### Команда 1.3: Получить Точные IDs

```bash
lspci -nn | grep -i nvidia
```

**Результат:**
```
01:00.0 VGA compatible controller: NVIDIA Corporation GP104 [GeForce GTX 1070] [10de:1b81]
```

Запомни: **10de:1b81** — это нужно для конфигурации passthrough.

### Команда 1.4: Проверить Текущий Драйвер

```bash
lspci -k | grep -A 2 "VGA"
```

Возможные результаты:
- `Kernel driver in use: nvidia` — NVIDIA драйвер уже установлен ✓
- `Kernel driver in use: nouveau` — Открытый драйвер (конфликтует с NVIDIA)
- `Kernel driver in use:` (пусто) — Драйвер не загружен

---

## 2. ДИАГНОСТИКА ПРОБЛЕМЫ РЕПОЗИТОРИЕВ

### Команда 2.1: Посмотреть Текущие Репозитории

```bash
cat /etc/apt/sources.list
```

**Вывод будет похож на:**
```
deb http://deb.debian.org/debian bookworm main
deb http://deb.debian.org/debian bookworm-updates main
deb http://security.debian.org bookworm-security main
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
```

### Команда 2.2: Проверить Наличие contrib/non-free

```bash
grep -c "contrib" /etc/apt/sources.list
```

**Результат:**
- `0` — **ПРОБЛЕМА!** Нужно добавить contrib/non-free
- `1` или больше — OK, репозитории настроены

### Команда 2.3: Проверить что Ядро Правильное

```bash
uname -r
apt-cache policy pve-headers
```

**Вывод должен быть:** версия ядра и доступные пакеты заголовков.

Если `pve-headers` не показывает ничего — репозитории неправильно настроены.

### Команда 2.4: Проверить Version Proxmox и Debian

```bash
cat /etc/issue
cat /etc/debian_version
```

**Результат для Proxmox 8.4:**
```
Debian GNU/Linux 12 \n \l
12.9
```

Кодовое имя Debian: **bookworm** (для 12.x)

---

## 3. ИСПРАВЛЕНИЕ РЕПОЗИТОРИЕВ

### Важно: Какая у тебя Версия Debian?

```bash
cat /etc/debian_version
```

**Соответствие версий:**
- `12.x` → `bookworm` (Proxmox 8.x, 9.x)
- `11.x` → `bullseye` (Proxmox 7.x)
- `10.x` → `buster` (Proxmox 6.x)

### Метод 1: Редактирование sources.list вручную (РЕКОМЕНДУЕТСЯ)

```bash
nano /etc/apt/sources.list
```

**Заменить содержимое на это (для Proxmox 8.4 / Debian 12 bookworm):**

```
# Debian официальный репозиторий
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware

# Debian Security
deb http://security.debian.org bookworm-security main contrib non-free

# Proxmox VE (no-subscription)
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
```

**Если хочешь использовать локальное зеркало (например, внутри сети):**

```
# Замени deb.debian.org на адрес твоего зеркала:
deb http://mirror.example.com/debian bookworm main contrib non-free non-free-firmware
deb http://mirror.example.com/debian bookworm-updates main contrib non-free non-free-firmware
```

**Сохранить файл:**
- Нажать `Ctrl+X`
- Нажать `Y` (Yes)
- Нажать `Enter`

### Метод 2: Автоматическое Добавление (Sed)

```bash
# Backup исходного файла
cp /etc/apt/sources.list /etc/apt/sources.list.bak

# Добавить contrib и non-free к существующим строкам Debian
sed -i 's/^deb http:\/\/deb.debian.org\/debian bookworm main$/deb http:\/\/deb.debian.org\/debian bookworm main contrib non-free non-free-firmware/' /etc/apt/sources.list
sed -i 's/^deb http:\/\/deb.debian.org\/debian bookworm-updates main$/deb http:\/\/deb.debian.org\/debian bookworm-updates main contrib non-free non-free-firmware/' /etc/apt/sources.list
sed -i 's/^deb http:\/\/security.debian.org bookworm-security main$/deb http:\/\/security.debian.org bookworm-security main contrib non-free/' /etc/apt/sources.list

# Проверить результат
cat /etc/apt/sources.list
```

### Метод 3: Полная Замена (если sources.list повреждён)

```bash
# Удалить старый файл
mv /etc/apt/sources.list /etc/apt/sources.list.old

# Создать новый с правильными репозиториями
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org bookworm-security main contrib non-free
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

# Проверить
cat /etc/apt/sources.list
```

### Шаг 3.4: Обновить Кэш Пакетов

```bash
apt update
```

**Вывод должен быть без ошибок (может быть предупреждение про "No valid subscription").**

**Если есть ошибки типа "Unable to locate repository":**
- Проверить URL в sources.list (опечатка в адресе)
- Проверить подключение к интернету: `ping deb.debian.org`
- Проверить что используешь правильное кодовое имя: `bookworm`

### Шаг 3.5: Проверить Доступность Пакетов

```bash
# Проверить что NVIDIA пакеты видны
apt-cache search nvidia-driver | head -10

# Проверить что pve-headers видны
apt-cache search pve-headers | head -5

# Дополнительная проверка
apt search "^pve-headers$"
apt search "^nvidia-driver$"
```

**Если видно результаты — репозитории исправлены правильно!**

---

## 4. УСТАНОВКА ЗАВИСИМОСТЕЙ

### Шаг 4.1: Обновить Систему

```bash
apt update
apt upgrade -y
```

Это может занять несколько минут.

### Шаг 4.2: Установить Build Tools

```bash
apt install build-essential dkms -y
```

**Что это:**
- `build-essential` — компилятор C/C++ и инструменты сборки
- `dkms` — Dynamic Kernel Module Support (для пересборки модулей при обновлении ядра)

### Шаг 4.3: Установить Заголовки Ядра

```bash
apt install linux-headers-$(uname -r) -y
```

Это установит заголовки для текущей версии ядра.

### Шаг 4.4: Установить pve-headers (Специфично для Proxmox)

```bash
apt install pve-headers -y
```

**Важно:** Это должно сработать теперь, после исправления репозиториев.

**Если всё ещё ошибка — выполни:**
```bash
apt-cache policy pve-headers
# Посмотри какие версии доступны
# и установи конкретную версию:
apt install pve-headers=<VERSION> -y
```

### Шаг 4.5: Отключить Nouveau (Если Конфликтует)

```bash
# Проверить установлен ли nouveau
lsmod | grep nouveau

# Если да — отключить его перед установкой NVIDIA
echo "blacklist nouveau" | tee -a /etc/modprobe.d/blacklist.conf
echo "options nouveau modeset=0" | tee -a /etc/modprobe.d/blacklist.conf

# Обновить initramfs
update-initramfs -u

# Перезагрузиться
reboot
```

После перезагрузки проверить:
```bash
lsmod | grep nouveau
# Не должно быть результата
```

---

## 5. УСТАНОВКА NVIDIA ДРАЙВЕРОВ

### Метод 1: Стандартная Установка (РЕКОМЕНДУЕТСЯ)

```bash
# Установить NVIDIA driver
apt install nvidia-driver -y

# Установить дополнительные пакеты
apt install libnvidia-cfg1 nvidia-kernel-source nvidia-kernel-common -y

# Перезагрузиться (ВАЖНО!)
reboot
```

### Метод 2: Если Версия Конкретная Нужна

```bash
# Посмотреть доступные версии
apt-cache policy nvidia-driver
apt search nvidia-driver | grep "^nvidia-driver"

# Установить конкретную версию (например, 550)
apt install nvidia-driver-550 -y

# Перезагрузиться
reboot
```

### Метод 3: Open-Source NVIDIA Driver (Если Проблемы с Proprietary)

```bash
# Для новых GPU можно использовать открытый драйвер
apt install nvidia-driver-open -y

# Перезагрузиться
reboot
```

### Метод 4: NVIDIA Cuda Toolkit (Если Нужен для Вычислений)

```bash
# Установить CUDA (дополнительно к драйверу)
apt install nvidia-cuda-toolkit -y

# Перезагрузиться
reboot
```

---

## 6. ПРОВЕРКА УСТАНОВКИ

### Команда 6.1: Базовая Проверка

```bash
nvidia-smi
```

**Успешный результат должен показать:**
```
+---------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.127.05             Driver Version: 550.127.05    CUDA Version: 12.4   |
+---------------------------------------------------------------------------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp  Perf          Pwr:Usage/Cap |         Memory-Usage | GPU-Util  Compute M. |
|   0  GeForce GTX 1070     Off | 0000:01:00.0 Off |                  N/A |
|  0%   37C  P0               24W / 250W |   1047MiB /  8192MiB |      0%      Default |
+---------------------------------------------------------------------------------------+
```

**Если ошибка "command not found":**
```bash
# Может быть PATH проблема
/usr/bin/nvidia-smi

# Или нужно перезагрузиться
reboot
```

### Команда 6.2: Проверить Модули

```bash
lsmod | grep nvidia
```

**Должны быть загружены модули:**
```
nvidia_drm
nvidia_uvm
nvidia
```

### Команда 6.3: Проверить Ядро Драйвера

```bash
lspci -k | grep -A 2 "VGA"
```

**Должно быть:**
```
Kernel driver in use: nvidia
```

### Команда 6.4: Мониторинг в Реальном Времени

```bash
watch -n 1 nvidia-smi
```

Нажать `Ctrl+C` для выхода.

### Команда 6.5: Полная Диагностика

```bash
# Информация о GPU
nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv

# Процессы на GPU
nvidia-smi pmon

# CUDA информация
nvidia-smi --query-gpu=compute_cap --format=csv

# Логирование в файл
nvidia-smi > /tmp/nvidia_info.txt
cat /tmp/nvidia_info.txt
```

---

## 7. РЕШЕНИЕ ПРОБЛЕМ

### Проблема 1: nvidia-smi - CUDA is not Available

```bash
# Это нормально если CUDA не установлена
# Драйвер работает, но CUDA toolkit не установлен
# Если нужен CUDA:
apt install nvidia-cuda-toolkit -y
reboot
```

### Проблема 2: nvidia-smi показывает "No Device Found"

```bash
# Шаг 1: Проверить видеокарта вообще видна
lspci | grep -i nvidia

# Если не видна:
# - Проверить BIOS (может быть отключена GPU)
# - Проверить слот PCI (может быть неисправен)
# - Попробовать другой слот

# Шаг 2: Если видна но не работает - перезагрузить PCI шину
echo 1 > /sys/bus/pci/rescan

# Шаг 3: Попробовать перезагрузиться
reboot
```

### Проблема 3: Ошибка "Kernel Module Build Failed"

```bash
# Проверить что заголовки установлены
apt install pve-headers -y

# Проверить что build-essential есть
apt install build-essential dkms -y

# Перестроить модули
dkms status
dkms autoinstall

# Если ошибка в логах - посмотреть:
dmesg | grep -i nvidia | tail -20
journalctl -xe | grep -i nvidia | tail -20
```

### Проблема 4: nouveau Драйвер Конфликтует

```bash
# Проверить что nouveau загружен
lsmod | grep nouveau

# Если да - отключить и перезагрузить
echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf
echo "options nouveau modeset=0" >> /etc/modprobe.d/nouveau-kms.conf
update-initramfs -u
reboot

# Проверить что отключился
lsmod | grep nouveau
# Не должно быть результата
```

### Проблема 5: Secure Boot Блокирует Установку

```bash
# Вариант 1: Отключить Secure Boot в BIOS (рекомендуется)
# - Перезагрузиться в BIOS/UEFI (обычно Del, F2, F12)
# - Найти Secure Boot и отключить
# - Сохранить и перезагрузиться в Linux

# Вариант 2: Использовать Open-Source драйвер
apt install nvidia-driver-open -y
reboot

# Вариант 3: Подписать модуль (продвинутый метод)
# Не рекомендуется для обычных пользователей
```

### Проблема 6: "Unable to locate package pve-headers"

```bash
# Проверить что contrib добавлен
grep "contrib" /etc/apt/sources.list

# Если не видно:
nano /etc/apt/sources.list
# Добавить contrib non-free к строкам

# Обновить пакеты
apt update

# Проверить что видно
apt-cache search pve-headers | head -5
```

### Проблема 7: Система Зависает После Установки NVIDIA

```bash
# Может быть проблема с тепловым управлением или C-States
# Отключить C-States в BIOS:
# - Перезагрузиться в BIOS
# - Найти C-State Control, CPU C States, или похожее
# - Отключить

# Или через GRUB:
nano /etc/default/grub
# Добавить параметры:
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_idle.max_cstate=1"
update-grub
reboot
```

---

## 8. ИСПОЛЬЗОВАНИЕ GPU ДЛЯ VM (GPU PASSTHROUGH)

### Шаг 8.1: Включить IOMMU в BIOS

Перезагрузиться в BIOS/UEFI:
- Найти "IOMMU" или "Intel VT-d" (Intel) / "AMD IOMMU" (AMD)
- Включить (Enable)
- Сохранить и выход

### Шаг 8.2: Включить IOMMU в GRUB

```bash
nano /etc/default/grub
```

Найти строку:
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
```

Изменить на (для Intel):
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

Или (для AMD):
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
```

Сохранить, применить и перезагрузиться:
```bash
update-grub
reboot
```

### Шаг 8.3: Проверить что IOMMU Работает

```bash
dmegs | grep -i iommu

# Для Intel должно быть:
# DMAR: IOMMU enabled

# Для AMD должно быть:
# AMD-Vi: IOMMU enabled
```

### Шаг 8.4: Добавить VFIO Модули

```bash
nano /etc/modules
```

Добавить эти строки:
```
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
```

Сохранить и выполнить:
```bash
update-initramfs -u
reboot
```

### Шаг 8.5: Blacklist GPU Драйверы на Хосте

```bash
nano /etc/modprobe.d/blacklist-gpu.conf
```

Для NVIDIA:
```
blacklist nvidia
blacklist nvidia_uvm
blacklist nvidiafb
```

Для AMD:
```
blacklist radeon
blacklist amdgpu
```

Сохранить и выполнить:
```bash
update-initramfs -u
reboot
```

### Шаг 8.6: Bind GPU к VFIO

Сначала получить IDs:
```bash
lspci -nn | grep -i nvidia
# Результат: 01:00.0 VGA compatible controller: NVIDIA Corporation... [10de:1b81]
```

Запомнить: **10de:1b81** (и может быть 10de:10f0 для audio)

Создать конфиг:
```bash
nano /etc/modprobe.d/vfio.conf
```

Добавить:
```
options vfio-pci ids=10de:1b81,10de:10f0 disable_vga=1
```

Сохранить и выполнить:
```bash
update-initramfs -u
reboot
```

### Шаг 8.7: Проверить что GPU в VFIO

```bash
lspci -k -s 01:00
# Должно быть: "Kernel driver in use: vfio-pci"
```

### Шаг 8.8: Использовать GPU в VM

В веб-интерфейсе Proxmox:
1. Открыть VM
2. Hardware → Add → PCI Device
3. Выбрать GPU (должна быть видна)
4. Включить опции:
   - x-vga=on (если нужен видео-выход)
   - pcie=1 (если PCIe)
5. Запустить VM

В VM будет полный доступ к GPU!

---

## 9. МОНИТОРИНГ И ДИАГНОСТИКА

### Команда 9.1: Непрерывный Мониторинг

```bash
# Обновляется каждую секунду
watch -n 1 nvidia-smi

# Или с температурами
watch -n 1 'nvidia-smi && echo "---" && nvidia-smi --query-gpu=index,temperature.gpu --format=csv'
```

### Команда 9.2: Процессы на GPU

```bash
# Какие процессы используют GPU
nvidia-smi pmon

# Более детально
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# Убить процесс если зависла
kill <PID>
# или более жестко
kill -9 <PID>
```

### Команда 9.3: Информация о GPU

```bash
# Базовая информация
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

# Температуры и тактовые частоты
nvidia-smi --query-gpu=index,name,temperature.gpu,clocks.current.sm,clocks.current.memory --format=csv

# Потребление энергии
nvidia-smi --query-gpu=index,power.draw,power.limit --format=csv

# Все параметры
nvidia-smi --help-query-gpu
```

### Команда 9.4: Логирование в Файл

```bash
# Периодически писать информацию в файл (каждые 10 секунд на 1 час)
nvidia-smi --query-gpu=timestamp,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw --format=csv,noheader -l 10 > /var/log/nvidia-usage.log &

# Посмотреть логи
tail -f /var/log/nvidia-usage.log

# Остановить логирование (найти PID и kill)
ps aux | grep nvidia-smi
kill <PID>
```

### Команда 9.5: Тестирование GPU

```bash
# Если установлен CUDA toolkit
# Базовый тест CUDA
deviceQuery

# Bandwidth тест
bandwidthTest

# Стресс-тест на 60 секунд (если есть nvidia-smi)
nvidia-smi -l 1 -q -d PERFORMANCE_STATE > /tmp/stress.log &
# Запустить нагрузку (например, передача данных на GPU)
# В другом терминале:
watch nvidia-smi
```

### Команда 9.6: Проверка Здоровья GPU

```bash
# Проверить что GPU реагирует
nvidia-smi -c RESET

# Посмотреть макс тактовую частоту
nvidia-smi --query-gpu=clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv

# Если есть ECC память (профессиональные GPU)
nvidia-smi --query-gpu=ecc.errors.corrected.volatile.total --format=csv
```

---

## ИТОГОВЫЙ ЧЕК-ЛИСТ УСТАНОВКИ

**Подготовка:**
- [ ] Проверить что видеокарта видна: `lspci | grep -i nvidia`
- [ ] Записать Bus ID и IDs видеокарты: `lspci -nn`
- [ ] Определить версию Debian: `cat /etc/debian_version`

**Исправление Репозиториев:**
- [ ] Отредактировать `/etc/apt/sources.list`
- [ ] Добавить `contrib non-free non-free-firmware`
- [ ] Выполнить `apt update`
- [ ] Проверить что пакеты видны: `apt search pve-headers`

**Установка Зависимостей:**
- [ ] `apt install build-essential dkms -y`
- [ ] `apt install pve-headers -y`
- [ ] Отключить nouveau если нужно: `echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf`
- [ ] `update-initramfs -u && reboot`

**Установка NVIDIA:**
- [ ] `apt install nvidia-driver -y`
- [ ] `reboot`
- [ ] Проверить: `nvidia-smi`

**GPU Passthrough (если нужен):**
- [ ] Включить IOMMU в BIOS
- [ ] Добавить параметры в GRUB
- [ ] Добавить VFIO модули
- [ ] Blacklist GPU драйверы на хосте
- [ ] Bind GPU к VFIO
- [ ] Проверить: `lspci -k -s <BUS:ID>`
- [ ] Использовать в VM

---

## АВТОМАТИЧЕСКИЙ СКРИПТ УСТАНОВКИ

Сохранить как `install_nvidia.sh`:

```bash
#!/bin/bash

set -e  # Выход при ошибке

echo "=== NVIDIA Driver Installation for Proxmox 8.4 ==="

# Проверить что пользователь root
if [ "$EUID" -ne 0 ]; then 
   echo "Этот скрипт должен быть запущен с правами root (sudo)"
   exit 1
fi

# Функция для вывода
print_step() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

# Шаг 1: Исправить репозитории
print_step "STEP 1: Fixing Repositories"

# Backup
cp /etc/apt/sources.list /etc/apt/sources.list.bak
echo "Backup сохранён в /etc/apt/sources.list.bak"

# Определить версию Debian
DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
if [ "$DEBIAN_VERSION" = "12" ]; then
    CODENAME="bookworm"
elif [ "$DEBIAN_VERSION" = "11" ]; then
    CODENAME="bullseye"
else
    echo "Неизвестная версия Debian: $DEBIAN_VERSION"
    exit 1
fi

echo "Detected Debian version: $DEBIAN_VERSION ($CODENAME)"

# Создать новый sources.list
cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian $CODENAME main contrib non-free non-free-firmware
deb http://deb.debian.org/debian $CODENAME-updates main contrib non-free non-free-firmware
deb http://security.debian.org $CODENAME-security main contrib non-free
deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription
EOF

echo "Sources.list updated:"
cat /etc/apt/sources.list

# Шаг 2: Update пакетов
print_step "STEP 2: Updating Package Lists"
apt update

# Шаг 3: Upgrade системы
print_step "STEP 3: Upgrading System"
apt upgrade -y

# Шаг 4: Установить зависимости
print_step "STEP 4: Installing Dependencies"
apt install -y build-essential dkms linux-headers-$(uname -r)

# Шаг 5: Установить pve-headers
print_step "STEP 5: Installing pve-headers"
apt install -y pve-headers

# Шаг 6: Отключить nouveau
print_step "STEP 6: Disabling Nouveau Driver"
if ! grep -q "blacklist nouveau" /etc/modprobe.d/blacklist.conf; then
    echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf
    echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist.conf
    echo "Nouveau blacklisted"
else
    echo "Nouveau already blacklisted"
fi

# Шаг 7: Обновить initramfs
print_step "STEP 7: Updating Initramfs"
update-initramfs -u

# Шаг 8: Установить NVIDIA
print_step "STEP 8: Installing NVIDIA Driver"
apt install -y nvidia-driver

# Итоговая информация
print_step "Installation Complete"
echo ""
echo "IMPORTANT: System reboot is required!"
echo "Command: reboot"
echo ""
echo "After reboot, verify with: nvidia-smi"
echo ""
echo "To remove this installation: apt remove nvidia-driver -y"
```

Запустить:
```bash
chmod +x install_nvidia.sh
sudo ./install_nvidia.sh
```

---

## БЫСТРАЯ СПРАВКА ДЛЯ КОМАНД

```bash
# Проверка
lspci | grep nvidia              # Есть ли видеокарта
lspci -k | grep -A 2 VGA         # Какой драйвер загружен
nvidia-smi                        # Статус NVIDIA
lsmod | grep nvidia              # Модули загружены

# Репозитории
cat /etc/apt/sources.list        # Текущие репозитории
apt update                        # Обновить кэш
apt search nvidia-driver          # Поиск пакетов

# Установка
apt install pve-headers -y       # Заголовки ядра
apt install nvidia-driver -y     # NVIDIA драйвер

# Управление
reboot                            # Перезагрузиться
update-initramfs -u              # Обновить initramfs

# Мониторинг
watch nvidia-smi                 # Мониторинг в реальном времени
nvidia-smi pmon                  # Процессы на GPU

# Troubleshooting
dmesg | grep nvidia              # Логи ядра
journalctl -xe                   # Systemd логи
tail -f /var/log/syslog          # Системный лог
```

---

**Версия документа:** 1.0
**Дата создания:** December 17, 2025
**Для:** Proxmox VE 8.4 на Debian 12 (Bookworm)
