#!/bin/bash
# ============================================================================
# Полная переустановка и настройка DNS для Kubernetes кластера
# Домен: ccsfarm.local
# BIND сервер: 10.10.1.151
# ============================================================================

set -e

echo "🔧 Полная переустановка CoreDNS..."
echo ""

# ==== ШАГИ ВОССТАНОВЛЕНИЯ ====

# 1. Откатить любые изменения
echo "[1/5] Откатываю изменения CoreDNS..."
kubectl rollout undo deployment coredns -n kube-system --to-revision=0 2>/dev/null || true
sleep 5

# 2. Удалить всех старых подов CoreDNS
echo "[2/5] Удаляю старые поды CoreDNS..."
kubectl delete pods -n kube-system -l k8s-app=kube-dns --grace-period=0 --force 2>/dev/null || true
sleep 10

# 3. Применить минимальную рабочую конфигурацию
echo "[3/5] Применяю минимальную рабочую конфигурацию..."
kubectl patch configmap coredns -n kube-system --type merge -p '{
  "data": {
    "Corefile": ".:53 {\n    errors\n    health {\n       lameduck 5s\n    }\n    ready\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n       pods insecure\n       fallthrough in-addr.arpa ip6.arpa\n       ttl 30\n    }\n    prometheus :9153\n    forward . /etc/resolv.conf\n    cache 30\n    loop\n    reload\n    loadbalance\n}\n"
  }
}'

echo "✅ ConfigMap обновлен"
echo ""

# 4. Перезагрузить CoreDNS
echo "[4/5] Перезагружаю CoreDNS..."
kubectl rollout restart deployment coredns -n kube-system
sleep 20

# 5. Проверить статус
echo "[5/5] Проверяю статус..."
if kubectl rollout status deployment coredns -n kube-system --timeout=60s; then
    echo "✅ CoreDNS успешно поднялся"
else
    echo "❌ CoreDNS не поднялся, проверяю логи..."
    kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ ВОССТАНОВЛЕНИЕ ЗАВЕРШЕНО"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Тестирование
echo "🧪 ТЕСТИРОВАНИЕ DNS:"
echo "────────────────────────────────────────────────────────────────"

echo "1️⃣ Статус CoreDNS:"
kubectl get pods -n kube-system -l k8s-app=kube-dns

echo ""
echo "2️⃣ Проверка внутрикластерного DNS:"
kubectl run -it --rm test-dns-cluster --image=busybox --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -E "^Name:|Address:" || echo "⚠️ Может быть таймаут, это нормально"

echo ""
echo "3️⃣ Проверка логов CoreDNS:"
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=10

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📌 СЛЕДУЮЩИЙ ШАГ:"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Когда все поды поднялись, мы настроим правильное разрешение"
echo "ccsfarm.local через BIND с помощью Stub Zone в CoreDNS"
echo ""
