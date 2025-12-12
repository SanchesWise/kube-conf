#!/bin/bash

# Полный список нод (FQDN)
NODES=(
    "k8s-master.ccsfarm.local"
    "k8s-control01.ccsfarm.local"
    "k8s-control02.ccsfarm.local"
    "k8s-worker01.ccsfarm.local"
    "k8s-worker02.ccsfarm.local"
    "k8s-worker03.ccsfarm.local"
    "k8s-worker04.ccsfarm.local"
)

# Создаем конфиг локально
cat <<EOF > local_mirrors.conf
[[registry]]
  prefix = "docker.io"
  location = "docker.io"
  [[registry.mirror]]
    location = "mirror.gcr.io"

[[registry]]
  prefix = "registry.k8s.io"
  location = "registry.k8s.io"
  [[registry.mirror]]
    location = "mirror.gcr.io"

[[registry]]
  prefix = "quay.io"
  location = "quay.io"
  [[registry.mirror]]
    location = "mirror.gcr.io"
EOF

# Запрашиваем SUDO пароль
echo -n "Введите SUDO пароль для пользователя $USER: "
read -s SUDO_PASS
echo ""
echo "Начинаем раскатку на ${#NODES[@]} нод..."

for NODE in "${NODES[@]}"; do
    echo "--------------------------------------------------"
    echo "📡 Подключение к: $NODE"

    # 1. Копируем файл во временную директорию (через SSH ключ)
    scp -o StrictHostKeyChecking=no -q local_mirrors.conf "$NODE:/tmp/99-gcr-mirror.conf"
    
    if [ $? -ne 0 ]; then
        echo "❌ Ошибка SCP. Проверьте доступность хоста или DNS."
        continue
    fi

    # 2. Применяем настройки через sudo
    ssh -o StrictHostKeyChecking=no "$NODE" "echo '$SUDO_PASS' | sudo -S -p '' sh -c '
        # Убедимся, что папка существует (на всякий случай)
        mkdir -p /etc/containers/registries.conf.d/
        
        # Перемещаем файл
        mv /tmp/99-gcr-mirror.conf /etc/containers/registries.conf.d/99-gcr-mirror.conf && \
        
        # Выставляем права
        chown root:root /etc/containers/registries.conf.d/99-gcr-mirror.conf && \
        chmod 644 /etc/containers/registries.conf.d/99-gcr-mirror.conf && \
        
        # Перезагружаем конфиг CRI-O
        systemctl reload crio
    '"

    if [ $? -eq 0 ]; then
        echo "✅ Успешно: Конфиг обновлен и CRI-O перезагружен."
    else
        echo "❌ Ошибка выполнения команд на ноде."
    fi
done

rm local_mirrors.conf
echo "--------------------------------------------------"
echo "🏁 Раскатка завершена."