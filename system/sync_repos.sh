#!/bin/bash

nodes=("10.10.2.101" "10.10.2.102" "10.10.2.103" "10.10.2.104" "10.10.2.105" "10.10.2.106" "10.10.2.107" "10.10.2.108" "10.10.2.109")

for node in "${nodes[@]}"; do
    echo "------------------------------------------"
    echo "Updating repos on $node..."
    
    # 1. Копируем файлы во временную директорию, где у пользователя есть права
    scp /etc/yum.repos.d/*.repo ccsfarm@$node:/tmp/
    
    # 2. Перемещаем файлы под sudo, меняем владельца и обновляем кэш
    # Используем ssh -t для запроса пароля sudo, если он требуется
    ssh -t ccsfarm@$node "sudo mv /tmp/*.repo /etc/yum.repos.d/ && \
                          sudo chown root:root /etc/yum.repos.d/*.repo && \
                          sudo dnf clean all && \
                          sudo dnf makecache"
done