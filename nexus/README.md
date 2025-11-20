Что делать после применения (kubectl apply -f nexus-install.yaml):

Дождитесь запуска: Nexus стартует долго (2-5 минут). Следите за подом: kubectl get pods -n nexus -w.

Узнайте пароль админа:
kubectl exec -it -n nexus <имя-пода> -- cat /nexus-data/admin.password

Зайдите в UI: Откройте http://nexus.ccsfarm.local (логин admin, пароль из пункта 2).

Настройте Docker-репозиторий внутри Nexus (Обязательно):
Создайте репозиторий: Create repository -> docker (hosted).
HTTP Port: В настройках репозитория поставьте галочку "HTTP" и впишите порт 8082.
Включите "Docker Bearer Token Realm" в разделе Security -> Realms.

Настройте клиенты (Docker/CRI-O):
Добавьте registry-nexus.ccsfarm.local в insecure-registries на всех машинах, так как у вас нет HTTPS.