#!/bin/bash

# --- КОНФИГУРАЦИЯ ---
NAMESPACE="minio"                                      # Неймспейс, где стоит MinIO
MINIO_SVC="minio.minio.svc.cluster.local"              # Внутренний адрес сервиса
MINIO_PORT="9000"                                      # Порт
MC_IMAGE="minio/mc:RELEASE.2024-11-05T11-29-45Z-cpuv1" # Версия клиента (как в вашей инструкции)

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== MinIO User & Bucket Creator ===${NC}"
echo "Этот скрипт создаст пользователя и бакеты в вашем MinIO кластере."
echo ""

# 1. Сбор данных
# Админские права (для подключения)
read -p "Введите MinIO Admin Access Key (по умолчанию 'admin'): " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "Введите MinIO Admin Secret Key (по умолчанию 'password'): " ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-password}
echo ""
echo "------------------------------------------------"

# Новый пользователь
read -p "Введите имя НОВОГО пользователя (например, 'loki'): " NEW_USER
if [ -z "$NEW_USER" ]; then
    echo -e "${RED}Ошибка: Имя пользователя не может быть пустым.${NC}"
    exit 1
fi

read -s -p "Придумайте пароль для $NEW_USER: " NEW_PASS
echo ""
if [ -z "$NEW_PASS" ]; then
    echo -e "${RED}Ошибка: Пароль не может быть пустым.${NC}"
    exit 1
fi

echo "------------------------------------------------"

# Бакеты
echo "Введите названия бакетов через пробел."
read -p "Пример (loki-data velero-backups gitlab-artifacts): " BUCKETS_LIST

echo ""
echo -e "${YELLOW}🚀 Запускаем временный под для настройки...${NC}"

# 2. Запуск задачи в Kubernetes
# Мы передаем переменные через --env, чтобы не экранировать их в командной строке
kubectl run minio-configurator-$(date +%s) \
    --rm -i --tty \
    --image="$MC_IMAGE" \
    --restart=Never \
    -n "$NAMESPACE" \
    --env="MINIO_ENDPOINT=http://$MINIO_SVC:$MINIO_PORT" \
    --env="ADMIN_USER=$ADMIN_USER" \
    --env="ADMIN_PASS=$ADMIN_PASS" \
    --env="NEW_USER=$NEW_USER" \
    --env="NEW_PASS=$NEW_PASS" \
    --env="BUCKETS=$BUCKETS_LIST" \
    --command -- /bin/sh -c '
        echo "🔌 Подключение к MinIO ($MINIO_ENDPOINT)..."
        # Устанавливаем алиас (подключение)
        if ! mc alias set myminio $MINIO_ENDPOINT $ADMIN_USER $ADMIN_PASS; then
           echo "❌ Ошибка подключения! Проверьте логин/пароль администратора."
           exit 1
        fi

        echo "👤 Создание пользователя $NEW_USER..."
        # Создаем юзера
        mc admin user add myminio $NEW_USER $NEW_PASS
        
        # Выдаем права readwrite
        echo "🔑 Назначение прав readwrite..."
        mc admin policy attach myminio readwrite --user $NEW_USER

        # Создание бакетов (цикл)
        if [ ! -z "$BUCKETS" ]; then
            for bucket in $BUCKETS; do
                echo "🪣 Создание бакета: $bucket"
                # --ignore-existing не выдаст ошибку, если бакет уже есть
                mc mb myminio/$bucket --ignore-existing
            done
        else
            echo "⚠️ Список бакетов пуст, пропускаем создание."
        fi
        
        echo "✅ Готово!"
    '

echo -e "${GREEN}🏁 Скрипт завершил работу.${NC}"