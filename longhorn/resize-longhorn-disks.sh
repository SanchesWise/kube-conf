#!/bin/bash
set -euo pipefail

# Список worker-нод
NODES=("k8s-worker01" "k8s-worker02" "k8s-worker03" "k8s-worker04")

DEVICE="/dev/sdb"
MOUNTPOINT="/mnt/longhorn-storage"

for NODE in "${NODES[@]}"; do
  echo "==================== $NODE ===================="

  ssh "$NODE" "lsblk"
  echo

  echo ">> Проверка, что $DEVICE смонтирован на $MOUNTPOINT"
  ssh "$NODE" "mount | grep '$MOUNTPOINT' || { echo 'ERROR: $MOUNTPOINT не смонтирован на $NODE'; exit 1; }"
  echo

  echo ">> Расширяем файловую систему ext4 на $DEVICE"
  ssh "$NODE" "sudo -S resize2fs $DEVICE"

  echo ">> Проверка размера $MOUNTPOINT после расширения:"
  ssh "$NODE" "df -h | grep '$MOUNTPOINT' || echo 'WARN: $MOUNTPOINT не найден в df -h'"

  echo
done

echo '✅ Расширение файловых систем на всех нодах завершено.'
echo 'Проверь Longhorn диски:'
echo '  ./check-longhorn-space.sh'
