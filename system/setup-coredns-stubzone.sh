#!/bin/bash
# ============================================================================
# Правильная настройка CoreDNS с Stub Zone для ccsfarm.local
# ============================================================================

echo "🔧 Настраиваю CoreDNS со Stub Zone для ccsfarm.local..."
echo ""

# Применить конфигурацию с явной Stub Zone
kubectl patch configmap coredns -n kube-system --type merge -p '{
  "data": {
    Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        
        # Kubernetes internal services
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        
        # Prometheus metrics
        prometheus :9153
        
        # Stub Zone для ccsfarm.local - форвардит на BIND
        ccsfarm.local:53 {
            errors
            cache 30
            forward . 10.10.1.151
        }
        
        # Forward everything else to system resolver
        forward . /etc/resolv.conf
        
        loop
        reload
        loadbalance
      }
  }
}'

echo "✅ ConfigMap обновлен"
echo ""

echo "🔄 Перезагружаю CoreDNS..."
kubectl rollout restart deployment coredns -n kube-system
sleep 20

echo "✅ CoreDNS перезагружен"
echo ""

echo "🧪 ТЕСТИРОВАНИЕ:"
echo "────────────────────────────────────────────────────────────────"

# Тест 1: Kubernetes DNS
echo "1️⃣ Kubernetes Service DNS:"
kubectl run -it --rm test-k8s --image=busybox --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -A 2 "Name:"

# Тест 2: BIND DNS
echo ""
echo "2️⃣ BIND DNS (ccsfarm.local):"
kubectl run -it --rm test-bind --image=busybox --restart=Never -- \
  nslookup registry-nexus.ccsfarm.local 2>&1 | grep -A 2 "Name:"

echo ""
echo "3️⃣ Проверка логов CoreDNS:"
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=5

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ НАСТРОЙКА ЗАВЕРШЕНА"
echo "════════════════════════════════════════════════════════════════"
