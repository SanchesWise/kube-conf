🆘 Disaster Recovery Guide: Etcd Restore

Дата создания: 23 Ноября 2025
Кластер: ccsfarm.local
Версия K8s: v1.28.15
Эта инструкция применяется, когда кластер полностью недоступен:
API серверы не отвечают.
База данных Etcd повреждена или потерян кворум.
Случайно удалены критические данные (Namespace, PV).

⚠️ ВАЖНО: Эта процедура деструктивна. Все данные, записанные в кластер после момента создания бэкапа, будут утеряны.
🛠 Предварительные требования
Доступ по SSH к Control-plane нодам (k8s-master, k8s-control01, k8s-control02).
Наличие файла бэкапа (обычно в /mnt/k8s-backup/etcd-backups/).
Права root.

🔄 Процедура восстановления
Мы восстановим кластер на одной ноде (например, k8s-master), удалим остальные из конфигурации, а затем присоединим их обратно как чистые ноды.
Шаг 1. Остановка кластера (на ВСЕХ Control-plane нодах)
Выполните это на k8s-master, k8s-control01, k8s-control02:
code
Bash
# Останавливаем kubelet, чтобы он не пытался перезапустить поды
systemctl stop kubelet

# Останавливаем контейнеры etcd и api-server (через удаление манифестов)
mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml.bak
mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak

# Ждем минуту, пока контейнеры остановятся
crictl ps | grep etcd # должно быть пусто


Шаг 2. Подготовка к восстановлению (Только на k8s-master)
Будем восстанавливать состояние на первой ноде.
Бэкап текущих (битых) данных:
code
Bash
mv /var/lib/etcd /var/lib/etcd.broken.$(date +%F)

Выбор файла бэкапа:

Найдите последний валидный бэкап:
code
Bash
ls -lt /mnt/k8s-backup/etcd-backups/
export BACKUP_FILE="/mnt/k8s-backup/etcd-backups/etcd-k8s-master-2025-11-XX_XXXXXX.db"

Восстановление снапшота:
Команда восстановит базу в локальную папку.
Важно: --initial-cluster должен содержать только текущую ноду!
code
Bash
etcdctl snapshot restore $BACKUP_FILE \
  --name k8s-master \
  --initial-cluster "k8s-master=https://10.10.2.100:2380" \
  --initial-cluster-token etcd-cluster-1 \
  --initial-advertise-peer-urls https://10.10.2.100:2380 \
  --data-dir /var/lib/etcd
(Замените 10.10.2.100 на реальный IP k8s-master)

Восстановление прав:
code
Bash
# Etcd должен принадлежать пользователю/группе etcd (если запускается не от root, проверьте настройки)
# В Kubeadm etcd запускается как static pod, обычно файлы root:root, но проверьте:
chown -R root:root /var/lib/etcd
chmod 0700 /var/lib/etcd

Шаг 3. Запуск первой ноды
Возвращаем манифесты на k8s-master:
code
Bash
mv /etc/kubernetes/manifests/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
mv /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
Запускаем Kubelet:
code
Bash
systemctl start kubelet

Ждем старта:
Это может занять до 5 минут. Проверяйте:
code
Bash
kubectl get nodes

Вы должны увидеть список нод. k8s-master будет Ready, остальные NotReady (так как они выключены).

Шаг 4. Очистка старых пиров (Важный шаг!)
Сейчас k8s-master думает, что он в кластере с остальными нодами, но их базы данных рассинхронизированы. Нужно удалить их из конфигурации Etcd и Kubernetes.

Удаление из Etcd:
code
Bash
# Получаем список участников
kubectl -n kube-system exec -it etcd-k8s-master -- etcdctl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key /etc/kubernetes/pki/etcd/healthcheck-client.key \
  member list

# Запишите ID старых нод (control01, control02).
# Удалите их по ID:
kubectl -n kube-system exec -it etcd-k8s-master -- etcdctl \
  --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key /etc/kubernetes/pki/etcd/healthcheck-client.key \
  member remove <MEMBER_ID>

Удаление из Kubernetes:
code
Bash
kubectl delete node k8s-control01
kubectl delete node k8s-control02

Шаг 5. Переподключение остальных Control-plane нод
Теперь у нас рабочий кластер из 1 мастера. Нужно "чисто" подключить остальные.
На k8s-control01 и k8s-control02:
Очистка данных:
code
Bash
rm -rf /var/lib/etcd/*
rm -f /etc/kubernetes/manifests/*.yaml # Убедитесь, что там нет ничего лишнего

Присоединение:
На k8s-master получите токен:
code
Bash
kubeadm token create --print-join-command

На остальных нодах выполните команду join, добавив флаг --control-plane.
code
Bash
kubeadm join 10.10.2.110:6443 --token ... --discovery-token-ca-cert-hash ... --control-plane

Шаг 6. Финал
Проверьте статус подов:
code
Bash
kubectl get pods -A
Если поды CNI (Calico) перезапустились и coredns работает — восстановление завершено.