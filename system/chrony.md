Это мемо (памятка) по инциденту с рассинхроном времени в кластере Kubernetes и инфраструктуре GitLab. Рекомендуется сохранить её в базу знаний (Wiki/Confluence) для предотвращения подобных проблем в будущем.

---

# Мемо: Критическая роль синхронизации времени в распределенных системах (Case: GitLab 500 Errors)

## 1. Описание инцидента
При миграции хранилищ GitLab на внешний Object Storage (MinIO) возникли массовые ошибки `500 Internal Server Error`, а также частичное отсутствие контента в репозиториях (коммитов, файлов). 

**Логи Webservice/Gitaly показали:**
`permission denied: token's validity window is in future`
`grpc_message: "permission denied: token's validity window is in future", grpc_status: 7`

## 2. Техническая причина (Root Cause)
**Clock Skew (Рассинхрон времени).**
GitLab использует JWT (JSON Web Tokens) для авторизации запросов между своими компонентами (Webservice <-> Gitaly).
1. **Webservice** генерирует токен с меткой времени «выдано в (iat) X».
2. **Gitaly** получает запрос и сравнивает X со своим системным временем.
3. Если время на ноде Gitaly **отстает** от времени Webservice более чем на несколько секунд, Gitaly считает, что токен пришел «из будущего» и отклоняет его как невалидный.

**Почему проблема обострилась:** При миграции поды перемещались между физическими хостами Proxmox. Разница во времени между нодами достигала **2-7 минут**, что полностью блокировало gRPC-взаимодействие.

## 3. Особенности среды (Proxmox + K8s)
*   **Виртуальные машины (KVM/RED OS):** Могут иметь собственный дрейф времени. Требуют установки и настройки `chrony`.
*   **LXC-контейнеры (Nexus, MinIO):** Используют ядро и системные часы **хоста Proxmox**. Попытка запустить `chrony` внутри LXC приводит к ошибке `adjtimex: Operation not permitted`, так как контейнер не имеет прав менять время ядра.

## 4. Реализованная архитектура синхронизации
Для исключения единой точки отказа и обеспечения минимальных задержек (jitter) внедрена иерархическая схема:

1.  **Эталон (Stratum 1/2):** Физические сервера Proxmox (`chia03, chia04, gpu-prox`). Синхронизируются с внешними пулами `pool.ntp.org`.
2.  **Клиенты (Stratum 3):** Все виртуальные машины (K8s Nodes, DB, Nexus VM). Синхронизируются одновременно со всеми **тремя** хостами Proxmox по локальной сети.
3.  **LXC-контейнеры:** Синхронизируются автоматически через обновление времени на хостах Proxmox.

## 5. Команды для быстрого восстановления

### Для физических хостов (Debian/Proxmox):
```bash
apt update && apt install -y chrony && printf "pool pool.ntp.org iburst\nallow 10.10.2.0/24\nlocal stratum 10\nrtcsync\n" > /etc/chrony/chrony.conf && systemctl restart chrony
```

### Для виртуальных машин (RED OS/RHEL):
```bash
dnf install -y chrony && systemctl stop chronyd && printf "server 10.10.1.53 iburst\nserver 10.10.1.54 iburst\nserver 10.10.1.55 iburst\nmakestep 1.0 3\nrtcsync\ndriftfile /var/lib/chrony/drift\n" > /etc/chrony.conf && chronyd -q 'server 10.10.1.53 iburst' && systemctl enable --now chronyd
```

### Проверка статуса:
```bash
# Посмотреть источники и разницу (offset)
chronyc sources -v
# Посмотреть текущую точность
chronyc tracking
```

## 6. Рекомендации по эксплуатации
1.  **Мониторинг:** Добавить в Prometheus/Alertmanager алерт на `node_clock_skew_seconds > 0.5`. 
2.  **LXC:** Никогда не пытаться настраивать NTP внутри LXC. Если время «уплыло» в контейнере — лечить нужно хост.
3.  **Deployments:** После исправления времени на «горячую», всегда выполнять `kubectl rollout restart` для Webservice и Gitaly, чтобы сбросить кэшированные сессии и токены.

---
**Статус:** Решено. Система синхронизирована. Ошибки 500 отсутствуют.