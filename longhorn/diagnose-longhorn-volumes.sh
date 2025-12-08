#!/bin/bash

echo "=== Проверка Longhorn Volumes на обеих локациях ==="
echo ""

for worker in 10.10.2.{103..106}; do
  echo "=== $worker ==="

  echo "📊 /var/lib/longhorn (OLD - sda):"
  ssh ccsfarm@$worker "sudo du -sh /var/lib/longhorn/* 2>/dev/null | sort -h" || echo "  ✗ Недоступно"

  echo ""
  echo "📊 /mnt/longhorn-storage (NEW - sdb):"
  ssh ccsfarm@$worker "sudo du -sh /mnt/longhorn-storage/* 2>/dev/null | sort -h" || echo "  ✗ Недоступно"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
done

echo ""
echo "=== Проверка Kubernetes PVC ==="
kubectl get pvc -A

echo ""
echo "=== Проверка Longhorn Volumes ==="
kubectl get volumes.longhorn.io -n longhorn-system
