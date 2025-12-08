#!/bin/bash

# ============================================================================
# 📊 Longhorn Disk Space Diagnostic (FIXED)
# ============================================================================

WORKERS=("10.10.2.103" "10.10.2.104" "10.10.2.105" "10.10.2.106")
SSH_USER="ccsfarm"
LONGHORN_PATH="/mnt/longhorn-storage"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  📊 Longhorn Disk Space Diagnostic                                  ║"
echo "║     Path: $LONGHORN_PATH"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "${BLUE}%-15s${NC} | ${BLUE}%-8s${NC} | ${BLUE}%-8s${NC} | ${BLUE}%-8s${NC} | ${BLUE}%-8s${NC} | ${BLUE}%-12s${NC}\n" \
    "NODE" "TOTAL" "USED" "AVAIL" "USE%" "STATUS"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

for worker in "${WORKERS[@]}"; do
    result=$(ssh "$SSH_USER@$worker" "df -h $LONGHORN_PATH 2>/dev/null | tail -1" 2>/dev/null)

    if [ -z "$result" ]; then
        printf "%-15s | ${RED}%-8s${NC} | %-8s | %-8s | ${RED}%-7s${NC} | ${RED}%-12s${NC}\n" \
            "$worker" "ERROR" "-" "-" "-" "✗ UNREACHABLE"
        continue
    fi

    total=$(echo "$result" | awk '{print $2}')
    used=$(echo "$result" | awk '{print $3}')
    avail=$(echo "$result" | awk '{print $4}')
    percent=$(echo "$result" | awk '{print $5}' | sed 's/%//')

    if ! [[ "$percent" =~ ^[0-9]+$ ]]; then
        percent="?"
    fi

    if [ "$percent" -ge 85 ] 2>/dev/null; then
        color="${RED}"
        status_text="✗ CRITICAL"
    elif [ "$percent" -ge 70 ] 2>/dev/null; then
        color="${YELLOW}"
        status_text="⚠ WARNING"
    else
        color="${GREEN}"
        status_text="✓ OK"
    fi

    printf "%-15s | %-8s | %-8s | %-8s | ${color}%-7s%%${NC} | ${color}%-12s${NC}\n" \
        "$worker" "$total" "$used" "$avail" "$percent" "$status_text"
done

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}✅ ДИАГНОСТИКА ЗАВЕРШЕНА${NC}"
