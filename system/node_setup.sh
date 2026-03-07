#!/bin/bash
set -e

# === КОНФИГУРАЦИЯ ===
K8S_VERSION="1.35"
CRIO_VERSION="v1.35"
DISK_DEV="/dev/sdb"
MOUNT_POINT="/mnt/longhorn-storage"
INTERFACE="ens18" # Проверьте, что интерфейс называется так (ip a)

# Проверка прав
if [ "$EUID" -ne 0 ]; then
  echo "❌ Запустите через sudo!"
  exit 1
fi

echo "🚀 [1/8] Базовая настройка ОС..."
# Отключаем Swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# SELinux Permissive
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Отключаем Firewalld (мешает сетям K8s)
systemctl stop firewalld || true
systemctl disable firewalld || true

echo "🛠️ [2/8] Настройка сети и DNS..."
# 1. Фикс чексумм для виртуалок (Proxmox/VirtIO)
dnf install -y ethtool
ethtool -K ${INTERFACE} tx off rx off

# Закрепляем фикс
cat <<EOF > /etc/systemd/system/disable-tx-offload.service
[Unit]
Description=Disable TX/RX checksumming
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K ${INTERFACE} tx off rx off
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-tx-offload.service

# 2. Модули ядра
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 3. Параметры Sysctl
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# 4. Настройка DNS (если нужно указать конкретные, раскомментируйте)
# echo "nameserver 1.1.1.1" > /etc/resolv.conf
# echo "nameserver 8.8.8.8" >> /etc/resolv.conf


echo "📦 [3/8] Настройка DNF (убираем залипания)..."
sed -i '/\[main\]/a ip_resolve=4\ntimeout=30\nminrate=1\nfastestmirror=False' /etc/dnf/dnf.conf
# Отключаем плагин подписок RedSoft
if [ -f /etc/dnf/plugins/subscription-manager.conf ]; then
    sed -i 's/enabled=1/enabled=0/' /etc/dnf/plugins/subscription-manager.conf
fi

echo "⏰ [4/8] Синхронизация времени..."
dnf install -y chrony
systemctl enable --now chronyd

echo "📦 [5/8] Установка CRI-O ${CRIO_VERSION}..."
OS="CentOS_8" # Совместимость для RED OS

# Чистим старые репо
rm -f /etc/yum.repos.d/devel:kubic* 
echo "📦 Удаление конфликтующего CRI-O 1.34..."
# Удаляем системный пакет RedOS, если он есть
dnf remove -y cri-o* conmon* container-selinux* || true
dnf clean all
#### репы уже накатаны через sync_repos.sh

dnf install -y cri-o --allowerasing

# Настройка cgroup driver = systemd
mkdir -p /etc/crio
crio config default > /etc/crio/crio.conf
sed -i 's/cgroup_manager = "cgroupfs"/cgroup_manager = "systemd"/' /etc/crio/crio.conf
sed -i 's/# conmon_cgroup = "pod"/conmon_cgroup = "pod"/' /etc/crio/crio.conf

systemctl enable --now crio

#### репы уже накатаны через sync_repos.sh

echo "📦 [6/8] Установка Kubernetes ..."
# # Ставим последние доступные версии из ветки 1.35
# 1. Останавливаем службу, чтобы не было конфликтов при удалении
systemctl stop kubelet || true

# 2. Удаляем старые пакеты (1.28) и CNI-плагины полностью
# Удаляем также kubernetes-cni, так как у 1.35 могут быть другие требования к версиям
dnf remove -y kubelet kubeadm kubectl kubernetes-cni || true

# 3. Очищаем кэш DNF, чтобы он увидел новые версии в Нексусе
dnf clean all
rm -rf /var/cache/dnf

# 4. Установка целевой версии 1.35
# Используем --allowerasing на случай конфликтов зависимостей
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes --allowerasing

echo "🔧 [7/8] Настройка Kubelet..."
# Указываем сокет CRI-O явно
cat <<EOF > /etc/sysconfig/kubelet
KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///var/run/crio/crio.sock --cgroup-driver=systemd
EOF

systemctl enable --now kubelet
echo "💾 [8/8] Подключение диска Longhorn..."
mkdir -p ${MOUNT_POINT}
DISK_UUID=$(blkid -s UUID -o value ${DISK_DEV})

if [ -z "$DISK_UUID" ]; then
    echo "⚠️ ВНИМАНИЕ: UUID для ${DISK_DEV} не найден!"
    echo "Если это новый пустой диск - отформатируйте его вручную: mkfs.ext4 ${DISK_DEV}"
    echo "Скрипт продолжает работу без монтирования диска..."
else
    if ! grep -q "${DISK_UUID}" /etc/fstab; then
        echo "UUID=${DISK_UUID} ${MOUNT_POINT} ext4 defaults 0 2" >> /etc/fstab
        echo "-> Запись добавлена в fstab."
    fi
    mount -a || echo "Ошибка монтирования (возможно уже смонтирован)"
    echo "-> Longhorn диск готов."
fi
echo "✅ [8/8] Нода готова к включению в кластер!"