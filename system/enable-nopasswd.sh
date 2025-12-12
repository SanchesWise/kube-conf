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

# Текущий пользователь, для которого включаем доступ
TARGET_USER=$USER

echo "=================================================="
echo "Включение SUDO без пароля для пользователя: $TARGET_USER"
echo "На списке нод: ${NODES[*]}"
echo "=================================================="

# Запрашиваем пароль один раз, чтобы применить настройки
echo -n "Введите текущий SUDO пароль (для применения настроек): "
read -s SUDO_PASS
echo ""
echo ""

for NODE in "${NODES[@]}"; do
    echo -n "[$NODE] Настройка... "

    # Мы используем SSH с пробросом пароля только один раз, чтобы создать файл
    # 1. Создаем файл в sudoers.d
    # 2. Выставляем права 0440 (обязательно для sudoers!)
    # 3. Проверяем, работает ли sudo без пароля (команда sudo -n true)
    
    ssh -o StrictHostKeyChecking=no "$NODE" "echo '$SUDO_PASS' | sudo -S -p '' sh -c '
        echo \"$TARGET_USER ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/90-nopasswd-$TARGET_USER && \
        chmod 0440 /etc/sudoers.d/90-nopasswd-$TARGET_USER
    '" 2>/dev/null

    # Проверка результата: пытаемся выполнить sudo без пароля (-n)
    if ssh -o StrictHostKeyChecking=no "$NODE" "sudo -n true" 2>/dev/null; then
        echo "✅ УСПЕШНО"
    else
        echo "❌ ОШИБКА (Возможно, неверный пароль или права)"
    fi
done

echo "=================================================="
echo "Готово. Теперь команды sudo на этих нодах не будут требовать пароль."