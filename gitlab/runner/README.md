# Gitlab runner

В WEB интерфейсе создай runner. Получите токен и подставьте eго значение в Secret.  

```shell
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: dev-gitlab-runner
  namespace: gitlab
type: Opaque
stringData:
  # Этот способ регистрации устаревший, с некоторыми проблемами. Поле всегда оставляем пустым.
  runner-registration-token: ""
  
  # тут подставляем полученный в WEB интерфейсе токен
  runner-token: "glrt-haAD9no41YLEnJfNEdJu"
  
  # S3 cache parameters
  accesskey: "admin"
  secretkey: "password"
EOF
```

```shell
helm repo add gitlab https://charts.gitlab.io/
helm repo update
helm search repo gitlab/gitlab
```

```shell
helm install dev-gitlab-runner gitlab/gitlab-runner -f my-values.yaml -n gitlab
```

```shell
helm uninstall dev-gitlab-runner -n gitlab
```

## Тестовый проект

За основу берем тестовые приложения из цикла видео про [tracing](../../tracing).

В GitLab создадим группу dev и проект base-application.

Переходим в директорию, где будут находиться ваши проекты.

```shell
git clone http://gitlab.kryukov.local/dev/base-application.git
```

Скопируем в директорию проекта файлы из директории 
[tracing/for_developersbase_application](../../tracing/for_developers/base_application).

Cоздадим файл `.gitlab-ci.yml`

```yaml
stages:
  - build
  - step1
  - step2

variables:
  REGISTRY: "https://index.docker.io/v1/"
  VERSION:
    value: ""
    description: "Введите tag (версию) контейнера. Пример: v0.0.1"

.build: &build_def
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:v1.11.0-debug
    entrypoint: [""]
  before_script:
    - |
      if [ -z $VERSION ]; then
        echo "Please select a container version"
        exit 1 
      fi
    - echo ${PROJECT_DIR}
    - echo ${CONTAINER_NAME}
    - echo "{\"auths\":{\"${REGISTRY}\":{\"auth\":\"$(printf "%s:%s" "${REGISTRY_USER}" "${REGISTRY_PASSWORD}" | base64 | tr -d '\n')\"}}}" > /kaniko/.docker/config.json
  script:
    - echo "Build container..."
    - /kaniko/executor 
      --context $PROJECT_DIR 
      --dockerfile $PROJECT_DIR/Dockerfile 
      --destination ${CONTAINER_NAME}
  tags:
    - stage
  when: manual
  only:
    - web

application1: 
  <<: *build_def
  variables:
    CONTAINER_NAME: bigkaa/gitlab-application1:${VERSION}
    PROJECT_DIR: ${CI_PROJECT_DIR}/application1

application2: 
  <<: *build_def
  variables:
    CONTAINER_NAME: bigkaa/gitlab-application2:${VERSION}
    PROJECT_DIR: ${CI_PROJECT_DIR}/application2

step1:
  stage: step1 
  cache:
    key: test-cache
    paths:
      - some_path/
  script:
    - mkdir some_path
    - echo "Hello from step1" > some_path/hello.txt 
  tags:
    - stage
  when: manual
  only:
    - web

step2:
  stage: step2 
  cache:
    key: test-cache
    paths:
      - some_path/
  script:
    - cat some_path/hello.txt
  tags:
    - stage
  when: manual
  only:
    - web
```

```shell
git status
```

```shell
git commit -m "initial commit"
git push
```

[Про использование кеш](https://docs.gitlab.com/ee/ci/caching/#cache-python-dependencies).

## Видео

* [VK](https://vk.com/video7111833_456239247)
* [Telegram](https://t.me/arturkryukov/282)
* [Rutube]() 
* [Zen](https://dzen.ru/video/watch/64c2051a2fe792267219e1db)
* [Youtube](https://youtu.be/LjIzdnJGgVA)


# Gitlab runner SSL

Создавать свой образ для этого — плохая практика (антипаттерн). Это заставит вас вручную пересобирать образ каждый раз, когда выходит новая версия GitLab Runner (а они выходят часто).
В Helm-чарте GitLab Runner есть штатный механизм для проброса своих CA-сертификатов без пересборки контейнеров.
Вот как это сделать правильно.
Шаг 1. Создайте Kubernetes Secret с вашим CA
Вам нужно положить ваш файл ccsfarm-ca.crt в секрет в том же namespace, где стоит раннер (допустим, это namespace gitlab).
Важно: Ключ внутри секрета должен иметь расширение .crt.

# Предполагаем, что вы в папке с файлом ccsfarm-ca.crt
Добавим в раннер наш СА

Самый надежный способ — позволить kubectl самому закодировать файл и выдать готовый YAML. Выполните эту команду в папке, где лежит ваш ccsfarm-ca.crt:

kubectl create secret generic custom-ca-certs \
  --namespace gitlab \
  --from-file=ccsfarm-ca.crt \
  --dry-run=client -o yaml > custom-ca-secret.yaml
Или сразу
# Предполагаем, что вы в папке с файлом ccsfarm-ca.crt
kubectl create secret generic custom-ca-certs \
  --namespace gitlab \
  --from-file=ccsfarm-ca.crt


Шаг 2. Обновите values.yaml
Вам нужно внести два изменения в ваш файл конфигурации:
Поменять протокол gitlabUrl на https.
Добавить параметр certsSecretName, указывающий на созданный секрет.
Вот исправленный фрагмент вашего values.yaml:


# 1. ОБЯЗАТЕЛЬНО меняем http на https, так как у вас теперь SSL
gitlabUrl: https://gitlab.ccsfarm.local/

# ... остальные настройки ...

# 2. Добавляем ссылку на секрет с сертификатом
# Это смонтирует сертификат в папку /home/gitlab-runner/.gitlab-runner/certs/
# Раннер автоматически подхватывает все .crt файлы из этой папки.
certsSecretName: custom-ca-certs

## !!! ВАЖНО !!!
# Чтобы git clone внутри запускаемых контейнеров (джобов) тоже работал 
# и не ругался на SSL, нужно прокинуть этот сертификат и внутрь подов сборки.
runners:
  config: |
    [[runners]]
      output_limit = 10000
      [runners.kubernetes]
        image = "registry.red-soft.ru/ubi8/ubi-micro"
        
        # Монтируем секрет с CA в каждый запускаемый под (job)
        [[runners.kubernetes.volumes.secret]]
          name = "custom-ca-certs"
          mount_path = "/etc/ssl/certs/ccsfarm-ca.crt"
          sub_path = "ccsfarm-ca.crt"
          read_only = true
          
        # (Опционально) Для некоторых образов (Alpine/RHEL) нужно задать переменную,
        # чтобы git знал, где искать этот файл, если update-ca-trust не отработал
        environment = ["SSL_CERT_FILE=/etc/ssl/certs/ccsfarm-ca.crt"]

      [runners.cache]
        Type = "s3"
        Path = ""
        Shared = true
        [runners.cache.s3]
          # Если MinIO внутри кластера доступен по HTTP, оставляем Insecure = true
          # Если MinIO тоже по HTTPS, то сертификат CA теперь есть, можно ставить Insecure = false
          ServerAddress = "minio.minio.svc.cluster.local:9000"
          BucketName = "dev-runner-cache"
          BucketLocation = "us-east-1"
          Insecure = true 
          AuthenticationType = "access-key"

# ... остальные настройки ...
Почему это лучше, чем свой образ?
Runner Pod (Менеджер): Параметр certsSecretName монтирует сертификат в системную папку раннера. При старте он видит ccsfarm-ca.crt, добавляет его в свое доверенное хранилище и успешно соединяется с https://gitlab.ccsfarm.local.
Job Pods (Сборщики): Секция [[runners.kubernetes.volumes.secret]] гарантирует, что когда раннер запустит под для сборки проекта, файл сертификата появится и внутри этого пода. Это критически важно, иначе команда git clone упадет с той же ошибкой SSL.
Примените изменения
code
Bash
helm upgrade --install gitlab-runner gitlab/gitlab-runner -f values.yaml -n gitlab
После этого под перезапустится и в логах вы увидите успешное Verifying runner... is alive.