В вашем манифесте всё в порядке. Отдельная консоль не нужна — она уже встроена в образ minio/minio (порт 9001), и вы её уже используете.

Почему нет раздела Users/Identity?
Это частая ситуация в MinIO, развернутом вручную. Интерфейс управления пользователями (Identity) появляется только если MinIO считает, что он работает в режиме полноценного кластера с правильной инициализацией, либо если вы зашли под корневым пользователем (MINIO_ROOT_USER), но браузер закешировал старый токен.

Однако, самый надежный способ управления MinIO в Kubernetes — это не UI, а консольная утилита mc (MinIO Client). Она работает через API и позволяет создавать пользователей даже тогда, когда в интерфейсе этой кнопки нет.

Давайте создадим пользователя loki и бакет loki-data через командную строку, не выходя из кластера.

Инструкция: Создание пользователя через CLI

Мы запустим временный под с утилитой mc, подключимся к вашему MinIO и сделаем всё необходимое.

1. Запустите временный под для администрирования:
Выполните в терминале:


kubectl run minio-admin -it --rm --image=minio/mc:RELEASE.2024-11-05T11-29-45Z-cpuv1 --restart=Never -n minio --command -- /bin/sh

(Вы попадете внутрь контейнера, командная строка сменится на sh-4.4# или похожее)

2. Подключитесь к вашему серверу MinIO:
Внутри этого пода выполните команду (используем ваши креды admin / password из манифеста):


# Синтаксис: mc alias set <имя_алиаса> <url> <user> <password>
mc alias set myminio http://minio.minio.svc.cluster.local:9000 admin password

Должно вывести: Added 'myminio' successfully.

3. Создайте пользователя для Loki:

code
Bash

# Создаем пользователя loki с паролем (замените на сложный!)
mc admin user add myminio loki SuperSecretLokiPassword123!

Должно вывести: Added user 'loki' successfully.

4. Назначьте пользователю права:
По умолчанию новый пользователь ничего не умеет. Дадим ему права readwrite (стандартная политика MinIO).

code
Bash

mc admin policy attach myminio readwrite --user loki

Должно вывести: Policy 'readwrite' is attached on user 'loki'.

5. Создайте бакет (если еще не создали в UI):

code
Bash

mc mb myminio/loki-data

6. Выход:
Нажмите Ctrl+D или введите exit. Временный под удалится сам.

Итог

Теперь у вас гарантированно есть:

Бакет: loki-data

Пользователь: loki

Пароль: SuperSecretLokiPassword123! (или тот, что вы ввели)

Теперь вы можете использовать эти данные в loki-values.yaml из предыдущего шага:

code
Yaml
download
content_copy
expand_less
storage:
      s3:
        endpoint: http://minio.minio.svc.cluster.local:9000
        bucketnames: loki-data
        access_key_id: loki
        secret_access_key: SuperSecretLokiPassword123!

Можно приступать к установке Loki (helm install...).