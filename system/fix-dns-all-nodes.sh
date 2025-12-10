#!/bin/bash
# ============================================================================
# Исправление DNS на всех нодах K8s кластера
# Удаляет resolvConf из kubelet конфига и перезагружает kubelet
# ============================================================================

set -e

NODES=(
  "10.10.2.100:k8s-master"
  "10.10.2.101:k8s-control01"
  "10.10.2.102:k8s-control02"
  "10.10.2.103:k8s-worker01"
  "10.10.2.104:k8s-worker02"
  "10.10.2.105:k8s-worker03"
  "10.10.2.106:k8s-worker04"
)

echo "🔧 Исправляю DNS конфигурацию на всех нодах K8s..."
echo "════════════════════════════════════════════════════════════════"
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

for NODE_INFO in "${NODES[@]}"; do
  IP="${NODE_INFO%:*}"
  NAME="${NODE_INFO#*:}"
  
  echo "[$(date +%H:%M:%S)] 📍 Обрабатываю: $NAME ($IP)"
  
  # Проверить текущую конфигурацию
  echo "  → Проверяю текущую конфигурацию..."
  CURRENT_CONFIG=$(ssh ccsfarm@$IP sudo cat /var/lib/kubelet/config.yaml 2>/dev/null | grep -E "clusterDNS|resolvConf" || echo "")
  
  if [ -n "$CURRENT_CONFIG" ]; then
    echo "    Текущие значения:"
    echo "$CURRENT_CONFIG" | sed 's/^/      /'
  else
    echo "    (нет DNS конфигурации)"
  fi
  
  # Удалить resolvConf если есть
  echo "  → Удаляю resolvConf из конфига..."
  if ssh ccsfarm@$IP sudo sed -i '/resolvConf:/d' /var/lib/kubelet/config.yaml 2>/dev/null; then
    echo "    ✅ Удалено"
  else
    echo "    ⚠️  Ошибка при редактировании"
  fi
  
  # Убедиться что clusterDNS указана на CoreDNS
  echo "  → Проверяю clusterDNS..."
  if ssh ccsfarm@$IP sudo grep -q "clusterDNS:" /var/lib/kubelet/config.yaml 2>/dev/null; then
    echo "    ✅ clusterDNS уже настроена"
  else
    echo "    ⚠️  clusterDNS не найдена (может быть добавлена автоматически)"
  fi
  
  # Перезагрузить kubelet
  echo "  → Перезагружаю kubelet..."
  if ssh ccsfarm@$IP sudo systemctl restart kubelet 2>/dev/null; then
    echo "    ✅ Перезагружен"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "    ❌ Ошибка при перезагрузке"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  
  # Дождаться, пока kubelet встанет
  echo "  → Жду запуска kubelet (макс 30 секунд)..."
  for i in {1..30}; do
    if ssh ccsfarm@$IP sudo systemctl is-active kubelet >/dev/null 2>&1; then
      echo "    ✅ kubelet запущен за $i сек"
      break
    fi
    if [ $i -eq 30 ]; then
      echo "    ⚠️  kubelet не запустился за 30 секунд"
    fi
    sleep 1
  done
  
  echo ""
done

echo "════════════════════════════════════════════════════════════════"
echo "✅ ИТОГО: $SUCCESS_COUNT успешно, $FAIL_COUNT ошибок"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Подождать пока ноды восстановятся в кластере
echo "⏳ Жду восстановления нод в кластере (макс 2 минуты)..."
for i in {1..24}; do
  READY_NODES=$(kubectl get nodes | grep -c " Ready " || echo "0")
  TOTAL_NODES=${#NODES[@]}
  
  if [ "$READY_NODES" -eq "$TOTAL_NODES" ]; then
    echo "✅ Все ноды готовы! ($READY_NODES/$TOTAL_NODES)"
    break
  fi
  
  if [ $((i % 4)) -eq 0 ]; then
    echo "  $READY_NODES/$TOTAL_NODES нод готовы... (ждём $(((24-i)*5)) сек)"
  fi
  sleep 5
done

echo ""
echo "📊 Статус нод:"
kubectl get nodes

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🗑️  Удаляю старые поды для пересоздания с новым DNS..."
echo "════════════════════════════════════════════════════════════════"

# Удалить все поды (они пересоздадутся с новым DNS)
kubectl delete pods -A --all --ignore-not-found=true &
PID=$!

echo "⏳ Жду удаления подов (макс 60 секунд)..."
for i in {1..60}; do
  if ! kill -0 $PID 2>/dev/null; then
    wait $PID
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    POD_COUNT=$(kubectl get pods -A --no-headers 2>/dev/null | wc -l || echo "?")
    echo "  Осталось подов: $POD_COUNT"
  fi
  sleep 1
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "⏳ Жду восстановления системных подов..."
echo "════════════════════════════════════════════════════════════════"

# Дождаться CoreDNS
echo "Жду CoreDNS..."
kubectl rollout status deployment/coredns -n kube-system --timeout=120s || echo "⚠️  Таймаут"

echo ""
echo "📊 Статус подов:"
kubectl get pods -n kube-system | grep -E "coredns|kube-dns"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ ИСПРАВЛЕНИЕ ЗАВЕРШЕНО"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "🧪 ТЕСТИРОВАНИЕ DNS:"
echo "────────────────────────────────────────────────────────────────"

# Тест DNS
echo "1️⃣ Тест Kubernetes DNS..."
kubectl run -it --rm test-k8s --image=busybox --restart=Never -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -A 1 "Name:" || echo "⚠️  Ошибка"

echo ""
echo "2️⃣ Тест BIND DNS (registry-nexus.ccsfarm.local)..."
kubectl run -it --rm test-bind --image=busybox --restart=Never -- nslookup registry-nexus.ccsfarm.local 2>&1 | grep -A 1 "Name:" || echo "⚠️  Ошибка"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ ГОТОВО!"
echo "════════════════════════════════════════════════════════════════"
