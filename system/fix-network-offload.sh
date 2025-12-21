cat << 'EOF' > fix-network-offload.sh
#!/bin/bash

# ==============================================================================
# АВТОМАТИЧЕСКАЯ НАСТРОЙКА ETHTOOL (TX OFF) ДЛЯ PROXMOX/VIRTIO
# ==============================================================================

# 1. Определяем основной сетевой интерфейс (через default route)
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)

if [ -z "$INTERFACE" ]; then
    echo "❌ Ошибка: Не удалось определить основной сетевой интерфейс."
    echo "Пожалуйста, введите имя интерфейса вручную (например, ens18):"
    read INTERFACE
fi

echo "✅ Выбран интерфейс: $INTERFACE"

# 2. Определяем путь к ethtool
ETHTOOL_PATH=$(which ethtool)
if [ -z "$ETHTOOL_PATH" ]; then
    echo "⚠️ Ethtool не найден. Устанавливаем..."
    if command -v dnf &> /dev/null; then
        dnf install -y ethtool
    elif command -v yum &> /dev/null; then
        yum install -y ethtool
    else
        echo "❌ Ошибка: не могу установить ethtool. Установите вручную."
        exit 1
    fi
    ETHTOOL_PATH=$(which ethtool)
fi

echo "✅ Ethtool найден: $ETHTOOL_PATH"

# 3. Создаем Systemd сервис
SERVICE_FILE="/etc/systemd/system/disable-tx-offload.service"

echo "📝 Создаем файл службы: $SERVICE_FILE"

cat <<UNIT > $SERVICE_FILE
[Unit]
Description=Disable TX Checksum Offloading for interface $INTERFACE (Proxmox UDP Fix)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ETHTOOL_PATH -K $INTERFACE tx off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# 4. Активируем и запускаем
echo "🔄 Перезагрузка демона systemd и активация службы..."
systemctl daemon-reload
systemctl enable disable-tx-offload.service
systemctl restart disable-tx-offload.service

# 5. Проверка
echo "---------------------------------------------------"
echo "🔍 ПРОВЕРКА РЕЗУЛЬТАТА:"
CURRENT_STATUS=$($ETHTOOL_PATH -k $INTERFACE | grep "tx-checksumming" | awk '{print $2}')

if [ "$CURRENT_STATUS" == "off" ]; then
    echo "✅ УСПЕХ: tx-checksumming is $CURRENT_STATUS"
else
    echo "❌ ОШИБКА: tx-checksumming is $CURRENT_STATUS (должен быть off)"
fi
echo "---------------------------------------------------"
EOF