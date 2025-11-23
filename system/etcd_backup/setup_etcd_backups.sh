#!/bin/bash

#Убедитесь, что на NFS сервере (10.10.1.53) есть папка /tank01/VM_storage/k8s-etcd-backups. Если нет — создайте её и дайте права на запись (например, chmod 777).

# Список Control-plane нод
MASTERS="k8s-master k8s-control01 k8s-control02"

# Параметры NFS
NFS_SERVER="10.10.1.53"
NFS_PATH="/tank01/VM_storage"
LOCAL_MOUNT="/mnt/k8s-backup"

# Версия etcdctl (должна совпадать или быть близкой к версии сервера, 3.5.x ок)
ETCD_VER="v3.5.9"

for NODE in $MASTERS; do
    echo -e "\n\033[1;33m🚀 Настройка бэкапов на $NODE...\033[0m"
    
    ssh -o StrictHostKeyChecking=no $NODE "sudo -S bash -c '
        # 1. Установка etcdctl (если нет)
        if ! command -v etcdctl &> /dev/null; then
            echo \"Installing etcdctl...\"
            curl -L https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd.tar.gz
            tar xzvf /tmp/etcd.tar.gz -C /tmp
            mv /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
            chmod +x /usr/local/bin/etcdctl
            rm -rf /tmp/etcd*
        fi

        # 2. Настройка NFS монтирования
        # Устанавливаем nfs-utils если нужно
        if ! rpm -q nfs-utils &> /dev/null; then dnf install -y nfs-utils; fi
        
        mkdir -p ${LOCAL_MOUNT}
        
        # Добавляем в fstab если нет
        if ! grep -q \"${LOCAL_MOUNT}\" /etc/fstab; then
            echo \"${NFS_SERVER}:${NFS_PATH} ${LOCAL_MOUNT} nfs defaults 0 0\" >> /etc/fstab
        fi
        
        # Монтируем
        mount -a
        mkdir -p ${LOCAL_MOUNT}/etcd-backups

        # 3. Создание скрипта бэкапа
        cat <<EOF > /usr/local/bin/etcd-snapshot.sh
#!/bin/bash
BACKUP_DIR=\"${LOCAL_MOUNT}/etcd-backups\"
DATE=\$(date +%Y-%m-%d_%H%M%S)
HOSTNAME=\$(hostname)

# Проверка, что NFS примонтирован (чтобы не забить локальный диск)
if ! mountpoint -q ${LOCAL_MOUNT}; then
    echo \"NFS not mounted, trying to mount...\"
    mount -a
    if ! mountpoint -q ${LOCAL_MOUNT}; then
        echo \"Critical: Backup storage unavailable\"
        exit 1
    fi
fi

# Создание снапшота
ETCDCTL_API=3 /usr/local/bin/etcdctl \\
  --endpoints=https://127.0.0.1:2379 \\
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \\
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \\
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \\
  snapshot save \$BACKUP_DIR/etcd-\$HOSTNAME-\$DATE.db

# Проверка статуса снапшота
if [ \$? -eq 0 ]; then
    echo \"Backup successful: etcd-\$HOSTNAME-\$DATE.db\"
    # Удаление старых бэкапов (старше 7 дней)
    find \$BACKUP_DIR -name \"etcd-\$HOSTNAME*.db\" -mtime +7 -delete
else
    echo \"Backup failed!\"
    exit 1
fi
EOF

        chmod +x /usr/local/bin/etcd-snapshot.sh

        # 4. Добавление в CRON (каждые 6 часов)
        if ! crontab -l | grep -q \"etcd-snapshot.sh\"; then
            (crontab -l 2>/dev/null; echo \"0 */6 * * * /usr/local/bin/etcd-snapshot.sh >> /var/log/etcd-backup.log 2>&1\") | crontab -
            echo \"Cron job added.\"
        fi
        
        # Тестовый запуск
        echo \"Testing backup script...\"
        /usr/local/bin/etcd-snapshot.sh
    '"
done

echo -e "\n\033[1;32m✅ Настройка завершена на всех нодах.\033[0m"