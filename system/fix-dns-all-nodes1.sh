#!/bin/bash
# ============================================================================
# Исправление DNS на всех нодах K8s кластера
# ============================================================================

NODES=(
  "10.10.2.100"
  "10.10.2.101"
  "10.10.2.102"
  "10.10.2.103"
  "10.10.2.104"
  "10.10.2.105"
  "10.10.2.106"
)

echo "🔧 Исправляю DNS конфигурацию на всех нодах K8s..."
echo "════════════════════════════════════════════════════════════════"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for IP in "${NODES[@]}"; do
  echo "[$(date +%H:%M:%S)] 📍 Обрабатываю: $IP"
  
  # Выполнить все команды одной сессией SSH
  ssh -o ConnectTimeout=5 ccsfarm@$IP << 'REMOTE_COMMANDS' 2>/dev/null
    
    # Проверить и отредактировать kubelet конфиг
    if grep -q "resolvConf:" /var/lib/kubelet/config.yaml; then
      echo "  → Удаляю resolvConf..."
      sudo sed -i '/resolvConf:/d' /var/lib/kubelet/config.yaml
      echo "    ✅ Удалено"
    else
      echo "  → resolvConf не найден"
    fi
    
    # Перезагрузить kubelet
    echo "  → Перезагружаю kubelet..."
    sudo systemctl restart kubelet
    echo "    ✅ Перезагружен"
    
    # Подождать запуска
    for i in {1..20}; do
      if sudo systemctl is-active kubelet >/dev/null 2>&1; then
        echo "    ✅ kubelet запущен"
        break
      fi
      sleep 1
    done

REMOTE_COMMANDS
  
  if [ $? -eq 0 ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "    ❌ Ошибка SSH"
  fi
  
  echo ""
done

echo "════════════════════════════════════════════════════════════════"
echo "✅ ИТОГО: $SUCCESS_COUNT успешно, $FAIL_COUNT ошибок"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Подождать пока ноды восстановятся
echo "⏳ Жду восстановления нод (макс 2 минуты)..."
for i in {1..24}; do
  READY=$(kubectl get nodes 2>/dev/null | grep -c " Ready " || echo "0")
  TOTAL=${#NODES[@]}
  
  if [ "$READY" -eq "$TOTAL" ]; then
    echo "✅ Все ноды готовы! ($READY/$TOTAL)"
    break
  fi
  
  echo -ne "\r  $READY/$TOTAL нод готовы... (осталось $((120-(i*5))) сек)"
  sleep 5
done

echo ""
echo ""
echo "📊 Статус нод:"
kubectl get nodes

echo ""
echo "🗑️  Удаляю все поды для пересоздания..."
kubectl delete pods -A --all --ignore-not-found=true 2>/dev/null &
sleep 30

echo "⏳ Жду восстановления CoreDNS..."
kubectl rollout status deployment/coredns -n kube-system --timeout=120s 2>/dev/null || true

echo ""
echo "📊 Статус CoreDNS:"
kubectl get pods -n kube-system -l k8s-app=kube-dns

echo ""
echo "🧪 ТЕСТИРОВАНИЕ DNS:"
echo "────────────────────────────────────────────────────────────────"

sleep 10

echo "1️⃣ Проверяю /etc/resolv.conf в поде:"
kubectl run -it --rm test-resolv --image=busybox --restart=Never -- cat /etc/resolv.conf 2>&1 | grep nameserver | head -3

echo ""
echo "2️⃣ Тест Kubernetes DNS:"
kubectl run -it --rm test-k8s --image=busybox --restart=Never -- nslookup kubernetes.default 2>&1 | grep -E "Name:|Address" | head -2

echo ""
echo "3️⃣ Тест BIND DNS (registry-nexus.ccsfarm.local):"
kubectl run -it --rm test-bind --image=busybox --restart=Never -- nslookup registry-nexus.ccsfarm.local 2>&1 | grep -E "Name:|Address" | head -2

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ ГОТОВО!"
echo "════════════════════════════════════════════════════════════════"
