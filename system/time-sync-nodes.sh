NODES="k8s-master k8s-control01 k8s-control02 k8s-worker01 k8s-worker02 k8s-worker03 k8s-worker04"

for NODE in $NODES; do
  echo -e "\n\033[1;33m🔄 Настройка $NODE...\033[0m"
  ssh -o StrictHostKeyChecking=no $NODE "sudo bash -c \"
    # 1. Делаем бэкап и комментируем старые серверы
    sed -i.bak -E 's/^(server|pool)/#\1/' /etc/chrony.conf;
    
    # 2. Добавляем надежные серверы (Яндекс + Google)
    echo -e '\nserver ntp.yandex.ru iburst\nserver time.google.com iburst\nserver 0.ru.pool.ntp.org iburst' >> /etc/chrony.conf;
    
    # 3. Перезагружаем сервис
    systemctl restart chronyd;
    sleep 3;
    
    # 4. Принудительно синхронизируем время
    chronyc makestep;
    
    # 5. Выводим результат
    chronyc sources;
  \""
done