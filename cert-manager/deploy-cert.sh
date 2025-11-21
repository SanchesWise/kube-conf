#!/bin/bash

# Настройки
CERT_NAME="ccsfarm-ca.crt"
IP_SUBNET="10.10.2"
START_IP=100
END_IP=106

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 1. Проверка наличия файла сертификата в текущей папке
if [ ! -f "$CERT_NAME" ]; then
    echo -e "${RED}Ошибка: Файл $CERT_NAME не найден в текущей директории!${NC}"
    echo "Сначала выполните: kubectl get secret ccsfarm-root-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d > $CERT_NAME"
    exit 1
fi

# 2. Запрашиваем пользователя SSH (чтобы не хардкодить root)
echo -n "Введите имя пользователя SSH для подключения к нодам (например, root или user): "
read SSH_USER

if [ -z "$SSH_USER" ]; then
    echo -e "${RED}Имя пользователя не может быть пустым${NC}"
    exit 1
fi

echo "----------------------------------------------------------------"
echo "Начинаем раскатку сертификата на ноды $IP_SUBNET.$START_IP - $IP_SUBNET.$END_IP"
echo "----------------------------------------------------------------"

for i in $(seq $START_IP $END_IP); do
    TARGET_IP="$IP_SUBNET.$i"

    echo -ne "Обработка ноды ${TARGET_IP}... "

    # Команды, которые будут выполнены на удаленном сервере:
    # 1. Перемещаем файл из /tmp в папку доверенных якорей
    # 2. Обновляем хранилище сертификатов
    # 3. Перезапускаем CRI-O
    # 4. Удаляем временный файл
    REMOTE_COMMANDS="sudo -S cp /tmp/$CERT_NAME /etc/pki/ca-trust/source/anchors/ && \
                     sudo -S update-ca-trust && \
                     sudo -S systemctl restart crio && \
                     rm -f /tmp/$CERT_NAME"

    # Шаг А: Копируем файл через SCP в /tmp (чтобы не было проблем с правами сразу в /etc)
    scp -o StrictHostKeyChecking=no -q "$CERT_NAME" "${SSH_USER}@${TARGET_IP}:/tmp/"

    if [ $? -eq 0 ]; then
        # Шаг Б: Выполняем настройку через SSH
        ssh -o StrictHostKeyChecking=no -q "${SSH_USER}@${TARGET_IP}" "$REMOTE_COMMANDS"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}[OK] Сертификат установлен, CRI-O перезапущен.${NC}"
        else
            echo -e "${RED}[ERROR] Ошибка при выполнении команд на сервере.${NC}"
        fi
    else
        echo -e "${RED}[ERROR] Не удалось скопировать файл (проверьте доступ/пароль).${NC}"
    fi
done

echo "----------------------------------------------------------------"
echo "Готово."
