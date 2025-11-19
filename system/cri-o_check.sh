# мониторинг состояния CRI-O
# bash
# Создадим простой мониторинг здоровья CRI-O
sudo cat <<'EOF' | sudo tee /usr/local/bin/crio-health-check.sh
#!/bin/bash
CRIO_SOCKET="/var/run/crio/crio.sock"
VOLATILE_FILE="/var/lib/containers/storage/overlay-containers/volatile-containers.json"

# Проверка socket
if [ ! -S "$CRIO_SOCKET" ]; then
    echo "ERROR: CRI-O socket not found at $CRIO_SOCKET"
    exit 1
fi

# Проверка файла volatile-containers.json (если существует)
if [ -f "$VOLATILE_FILE" ]; then
    if ! jq empty "$VOLATILE_FILE" 2>/dev/null; then
        echo "WARNING: $VOLATILE_FILE might be corrupted"
        # Можно автоматически восстанавливать, но пока просто предупреждение
    fi
fi

# Проверка через crictl
if ! crictl version >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to CRI-O via crictl"
    exit 1
fi

echo "CRI-O health check: OK"
exit 0
EOF

sudo chmod +x /usr/local/bin/crio-health-check.sh
# Добавим в systemd службу для периодической проверки
# bash
# Создаем службу для мониторинга
sudo cat <<'EOF' | sudo tee /etc/systemd/system/crio-health-check.service
[Unit]
Description=CRI-O Health Check
After=crio.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/crio-health-check.sh
User=root
EOF

sudo cat <<'EOF' | sudo tee /etc/systemd/system/crio-health-check.timer
[Unit]
Description=Run CRI-O health check every 5 minutes
Requires=crio-health-check.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable crio-health-check.timer
sudo systemctl start crio-health-check.timer