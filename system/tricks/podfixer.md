
Вы столкнулись с важным архитектурным нюансом: то, что вы видите в /mnt/longhorn-storage — это бэкенд Longhorn. Там лежат «сырые» данные реплик (файлы .img), а не сами файлы вашего Nexus.
Чтобы удалить frozen.marker, нам нужно залезть внутрь файловой системы самого тома. Поскольку вы уже остановили Nexus (replica=0), том сейчас не примонтирован ни к одной ноде.
Самый простой и безопасный способ сделать это — запустить временный «под-ремонтник» в Kubernetes.
Шаг 1: Запуск ремонтного пода
Выполните эту команду на мастере. Она создаст временный контейнер, который примонтирует ваш диск с базой Nexus:
code
Bash
kubectl run -i --tty --rm nexus-fixer --image=busybox --restart=Never -n nexus --overrides='
{
  "spec": {
    "containers": [{
      "name": "fixer",
      "image": "busybox",
      "command": ["sh"],
      "stdin": true,
      "tty": true,
      "volumeMounts": [{
        "name": "data",
        "mountPath": "/nexus-repair"
      }]
    }],
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {
        "claimName": "nexus-data-ssd"
      }
    }]
  }
}'
Шаг 2: Удаление файлов внутри ремонтного пода
Когда вы окажетесь внутри консоли пода (появится символ / #), выполните:
code
Bash
# 1. Заходим в папку с базой
cd /nexus-repair/db/

# 2. Проверяем наличие маркера
ls -la frozen.marker

# 3. Удаляем его
rm -f frozen.marker

# 4. Удаляем возможные блокировки OrientDB
find . -name "*.lock" -delete

# 5. Выходим
exit