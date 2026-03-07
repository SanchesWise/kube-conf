#!/bin/bash

# Пользователь для SSH (с правами sudo без пароля)
SSH_USER="ccsfarm"

# Список всех 8 воркеров
WORKERS=(
    "k8s-worker01.ccsfarm.local"
    "k8s-worker02.ccsfarm.local"
    "k8s-worker03.ccsfarm.local"
    "k8s-worker04.ccsfarm.local"
    "k8s-worker05.ccsfarm.local"
    "k8s-worker06.ccsfarm.local"
    "k8s-worker07.ccsfarm.local"
    "k8s-worker08.ccsfarm.local"
)

# Проверка наличия скрипта настройки
if [ ! -f "node_setup.sh" ]; then
    echo "❌ Ошибка: Файл node_setup.sh не найден!"
    exit 1
fi

echo "🔑 Генерируем Join-токен..."
if [ "$EUID" -ne 0 ]; then
    # Добавляем --cri-socket, чтобы kubeadm на воркере точно знал, куда стучаться
    JOIN_CMD=$(sudo kubeadm token create --print-join-command)
else
    JOIN_CMD=$(kubeadm token create --print-join-command)
fi

# Добавляем аргумент сокета к команде джойна
JOIN_CMD="$JOIN_CMD --cri-socket=unix:///var/run/crio/crio.sock"

echo "🚀 Начинаем деплой на ${#WORKERS[@]} нод..."

for NODE in "${WORKERS[@]}"; do
    echo "--------------------------------------------------"
    echo "🖥️  Нода: $NODE"
    echo "--------------------------------------------------"

    # 1. Очистка SSH ключей (на случай переустановки)
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$NODE" >/dev/null 2>&1 || true

    # 2. Проверка доступности
    if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $SSH_USER@$NODE "echo Connection OK"; then
        echo "⚠️  Недоступна. Пропускаем."
        continue
    fi

    # 3. Доставка скрипта
    echo "📦 Копирование скрипта..."
    scp -o StrictHostKeyChecking=no node_setup.sh $SSH_USER@$NODE:~/node_setup.sh

    # 4. Настройка (Setup)
    echo "⚙️  Запуск настройки окружения..."
    if ssh -o StrictHostKeyChecking=no $SSH_USER@$NODE "sudo chmod +x ~/node_setup.sh && sudo ~/node_setup.sh"; then
        echo "✅ Окружение настроено."
    else
        echo "❌ Ошибка настройки! Пропускаем джойн."
        continue
    fi

    # 5. Ввод в кластер (Join)
    echo "🔗 Подключение к кластеру..."
    # Reset на всякий случай перед джойном, чтобы убрать хвосты неудачных попыток
    ssh -o StrictHostKeyChecking=no $SSH_USER@$NODE "sudo kubeadm reset -f --cri-socket=unix:///var/run/crio/crio.sock || true"
    
    if ssh -o StrictHostKeyChecking=no $SSH_USER@$NODE "sudo $JOIN_CMD"; then
        echo "🎉 УСПЕХ: $NODE добавлена в кластер!"
    else
        echo "❌ ОШИБКА: Не удалось добавить $NODE."
    fi
done

echo "=================================================="
echo "Готово. Проверьте статус: kubectl get nodes"