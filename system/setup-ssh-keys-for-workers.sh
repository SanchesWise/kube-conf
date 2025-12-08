#!/bin/bash

# ============================================================================
# 🔐 SSH Key Distribution for K8s Cluster (ccsfarm с sudo)
# ============================================================================
# Распределяет SSH публичный ключ на пользователя ccsfarm с правами root
# Требует: ssh, ssh-keygen, ssh-copy-id, sshpass
# ============================================================================

set -e  # Выход при первой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# КОНФИГУРАЦИЯ
# ============================================================================

# Список worker-нод (реальные IP адреса)
WORKERS=(
  "10.10.2.103"
  "10.10.2.104"
  "10.10.2.105"
  "10.10.2.106"
)

# SSH пользователь на worker-нодах (НЕ root!)
SSH_USER="ccsfarm"

# Порт SSH (обычно 22)
SSH_PORT="22"

# Путь к приватному SSH ключу (если не стандартный)
SSH_KEY="${HOME}/.ssh/id_rsa"

# Timeout для SSH операций
SSH_TIMEOUT="10"

# Пароль (будет запрошен интерактивно)
SSH_PASSWORD=""

# ============================================================================
# ФУНКЦИИ
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Проверка зависимостей
check_dependencies() {
    log_info "Проверяем зависимости..."

    local missing_deps=0

    for cmd in ssh ssh-keygen ssh-copy-id; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd не найден"
            missing_deps=$((missing_deps + 1))
        else
            log_success "$cmd найден"
        fi
    done

    # Проверяем sshpass (ОБЯЗАТЕЛЕН для работы со скриптом)
    if ! command -v "sshpass" &> /dev/null; then
        log_error "sshpass НЕ НАЙДЕН (требуется для работы со скриптом)"
        log_warning "Установи: sudo apt-get install sshpass"
        exit 1
    else
        log_success "sshpass найден"
    fi

    if [ $missing_deps -gt 0 ]; then
        log_error "Некоторые зависимости не установлены"
        exit 1
    fi
}

# Запрос пароля у пользователя
prompt_password() {
    echo ""
    log_info "Введи пароль для SSH пользователя '$SSH_USER' на worker-нодах:"
    log_warning "ВАЖНО: пользователь '$SSH_USER' должен иметь права root через sudo!"
    read -s -p "Пароль: " SSH_PASSWORD
    echo ""

    if [ -z "$SSH_PASSWORD" ]; then
        log_error "Пароль не может быть пустым"
        exit 1
    fi

    log_success "Пароль принят"
}

# Проверка наличия SSH-ключа
check_ssh_key() {
    log_info "Проверяем SSH-ключ..."

    if [ ! -f "$SSH_KEY" ]; then
        log_warning "SSH-ключ не найден: $SSH_KEY"
        log_info "Генерируем новый SSH-ключ..."

        ssh-keygen -t ed25519 \
            -f "$SSH_KEY" \
            -N "" \
            -C "k8s-master-$(hostname)" \
            || {
                log_error "Не удалось создать SSH-ключ"
                exit 1
            }

        log_success "SSH-ключ создан: $SSH_KEY"
    else
        log_success "SSH-ключ существует: $SSH_KEY"
    fi

    # Проверяем права доступа
    if [ $(stat -f%OLp "$SSH_KEY" 2>/dev/null || stat -c%a "$SSH_KEY") != "600" ]; then
        log_warning "Исправляем права на приватный ключ..."
        chmod 600 "$SSH_KEY"
        log_success "Права исправлены: 600"
    fi
}

# Добавляем host в known_hosts
add_to_known_hosts() {
    local host=$1

    log_info "Добавляем $host в known_hosts..."

    # Удаляем старую запись (если есть)
    ssh-keygen -R "$host" 2>/dev/null || true

    # Добавляем новую запись
    if ssh-keyscan -p "$SSH_PORT" -t ed25519,rsa "$host" >> "${HOME}/.ssh/known_hosts" 2>/dev/null; then
        log_success "$host добавлен в known_hosts"
        return 0
    else
        log_warning "$host недоступен или не ответил на ssh-keyscan"
        return 1
    fi
}

# Копируем ключ на worker-ноду (для пользователя ccsfarm)
copy_key_to_worker() {
    local worker=$1

    log_info "Копируем ключ на $worker для пользователя $SSH_USER..."

    # Проверяем доступ с паролем
    if ! timeout "$SSH_TIMEOUT" sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT" \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -o PasswordAuthentication=yes \
        "$SSH_USER@$worker" "echo OK" &>/dev/null; then

        log_error "Не удалось подключиться к $worker (неверный пароль или пользователь?)"
        return 1
    fi

    log_success "Соединение с $worker успешно"

    # Копируем публичный ключ через sshpass
    if sshpass -p "$SSH_PASSWORD" ssh-copy-id -p "$SSH_PORT" \
        -i "$SSH_KEY.pub" \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "$SSH_USER@$worker" &>/dev/null; then

        log_success "Ключ скопирован в ~/.ssh/authorized_keys на $worker"
        return 0
    else
        log_error "Не удалось скопировать ключ на $worker"
        return 1
    fi
}

# Проверяем доступ без пароля
verify_access() {
    local worker=$1

    log_info "Проверяем доступ без пароля к $worker..."

    if timeout "$SSH_TIMEOUT" ssh -p "$SSH_PORT" \
        -o ConnectTimeout=5 \
        -o PasswordAuthentication=no \
        -o PubkeyAuthentication=yes \
        "$SSH_USER@$worker" "whoami" &>/dev/null; then

        log_success "Доступ без пароля к $worker: ✓"
        return 0
    else
        log_error "Доступ без пароля к $worker: ✗"
        return 1
    fi
}

# ============================================================================
# ГЛАВНАЯ ПРОГРАММА
# ============================================================================

main() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  🔐 SSH Key Distribution for K8s Cluster                  ║"
    echo "║     (пользователь: $SSH_USER с правами root)             ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log_info "Начинаем распределение SSH-ключей..."
    echo ""

    # Проверяем зависимости
    check_dependencies
    echo ""

    # Запрашиваем пароль
    prompt_password
    echo ""

    # Проверяем SSH-ключ
    check_ssh_key
    echo ""

    # Счётчики
    total=${#WORKERS[@]}
    success=0
    failed=0
    failed_workers=()

    # Для каждой worker-ноды
    for worker in "${WORKERS[@]}"; do
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        log_info "Обработка: $worker"
        echo ""

        # Добавляем в known_hosts
        if ! add_to_known_hosts "$worker"; then
            log_warning "Пропускаем $worker (хост недоступен)"
            failed=$((failed + 1))
            failed_workers+=("$worker")
            echo ""
            continue
        fi
        echo ""

        # Копируем ключ (с паролем)
        if ! copy_key_to_worker "$worker"; then
            failed=$((failed + 1))
            failed_workers+=("$worker")
            echo ""
            continue
        fi
        echo ""

        # Проверяем доступ
        if ! verify_access "$worker"; then
            log_warning "$worker добавлена, но доступ не подтверждён"
            failed=$((failed + 1))
            failed_workers+=("$worker")
            echo ""
            continue
        fi
        echo ""

        success=$((success + 1))
    done

    # Итоги
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📊 ИТОГИ${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Всего worker-нод: $total"
    echo -e "  ${GREEN}✓ Успешно: $success${NC}"
    echo -e "  ${RED}✗ Ошибок: $failed${NC}"
    echo ""

    if [ $failed -gt 0 ]; then
        echo -e "${YELLOW}Хосты с ошибками:${NC}"
        for worker in "${failed_workers[@]}"; do
            echo "  - $worker"
        done
        echo ""
    fi

    # Финальная проверка (параллельная)
    echo -e "${BLUE}🔍 Финальная проверка всех нод...${NC}"
    echo ""

    all_ok=true
    for worker in "${WORKERS[@]}"; do
        if timeout "$SSH_TIMEOUT" ssh -p "$SSH_PORT" \
            -o ConnectTimeout=5 \
            -o PasswordAuthentication=no \
            "$SSH_USER@$worker" "echo -n" &>/dev/null; then

            echo -e "  ${GREEN}✓${NC} $worker"
        else
            echo -e "  ${RED}✗${NC} $worker"
            all_ok=false
        fi
    done

    echo ""
    if [ "$all_ok" = true ] && [ $success -eq $total ]; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  ✅ Все worker-ноды готовы к беспарольному доступу!      ║${NC}"
        echo -e "${GREEN}║     ssh $SSH_USER@<worker> (без пароля)                  ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Примеры команд с sudo:"
        echo "  ssh $SSH_USER@10.10.2.103 'sudo whoami'"
        echo "  ssh $SSH_USER@10.10.2.103 'sudo df -h'"
        echo "  ssh $SSH_USER@10.10.2.103 'sudo systemctl status kubelet'"
        echo ""
        return 0
    else
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠️  Некоторые worker-ноды недоступны                      ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Проверьте:"
        echo "  1. Доступность хостов (ping)"
        echo "  2. SSH порт ($SSH_PORT)"
        echo "  3. Учетные данные (пользователь: $SSH_USER)"
        echo "  4. Пароль"
        echo "  5. Что у $SSH_USER есть права root в sudoers"
        echo ""
        return 1
    fi
}

# Запуск
main "$@"
