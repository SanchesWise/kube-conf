Поднятие внешнего Nexus в LXC — отличное решение. Это позволит кэшировать пакеты один раз и раздавать их по 20Gb-интерлинку всем нодам кластера, полностью игнорируя нестабильность внешнего канала и проблемы с MTU при скачивании тяжелых метаданных.

Параметры LXC контейнера (рекомендуемые)

Имя: nexus-external

ID: 500 (или любой свободный)

ОЗУ: 8 ГБ (Nexus — это Java, 4 ГБ — минимум, 8 ГБ — комфортно для кэширования).

CPU: 2–4 ядра.

Диск ОС: 16 ГБ на ssd05.

Диск данных (хранилище): 500 ГБ+ на hdd-raid.

Шаг 1: Подготовка хранилища на хосте (Gpu-prox)

Создадим отдельный датасет ZFS для данных Nexus. Это позволит нам делать снапшоты только данных и ограничивать квоту.

code
Bash
download
content_copy
expand_less
# Создаем датасет
zfs create hdd-raid/nexus-data

# Устанавливаем квоту (например, 500 ГБ, потом можно расширить)
zfs set quota=500G hdd-raid/nexus-data

# Устанавливаем права (Nexus внутри LXC будет иметь UID 200)
# Но для начала просто создадим папку
mkdir -p /hdd-raid/nexus-data
Шаг 2: Создание LXC контейнера

Используйте шаблон Debian 12 (или RedOS, если привыкли).

Создайте контейнер через GUI или CLI.

Сетевые настройки:

IPv4: 10.10.1.60/22 (или любой свободный).

Gateway: 10.10.1.1.

Монтирование рейда:
Отредактируйте конфиг контейнера на хосте:

code
Bash
download
content_copy
expand_less
nano /etc/pve/lxc/500.conf

Добавьте строку в конец:

code
Text
download
content_copy
expand_less
mp0: /hdd-raid/nexus-data,mp=/opt/sonatype/sonatype-work
Шаг 3: Установка Nexus внутри LXC

Зайдите в контейнер (pct enter 500).

Установка Java (Nexus 3.x требует Java 17):

code
Bash
download
content_copy
expand_less
apt update && apt install openjdk-17-jre-headless -y

Создание пользователя:

code
Bash
download
content_copy
expand_less
useradd -d /opt/sonatype -s /bin/bash nexus

Скачивание и установка:
Поскольку это nexus-external, скачиваем бинарник извне:

code
Bash
download
content_copy
expand_less
cd /opt/sonatype
# Ссылка на актуальную версию
wget https://download.sonatype.com/nexus/3/nexus-3.89.1-02-linux-x86_64.tar.gz
tar -xvf nexus-3.89.1-02-linux-x86_64.tar.gz
# Убираем версию из названия папки для удобства
mv nexus-3.* nexus
chown -R nexus:nexus /opt/sonatype

Настройка запуска от пользователя nexus:

code
Bash
download
content_copy
expand_less
nano /opt/sonatype/nexus/bin/nexus.rc
# Раскомментируйте и измените:
run_as_user="nexus"

Создание Systemd сервиса:

code
Bash
download
content_copy
expand_less
nano /etc/systemd/system/nexus.service

Вставьте:

code
Unit
download
content_copy
expand_less
[Unit]
Description=nexus service
After=network.target

[Service]
Type=forking
LimitNOFILE=65536
ExecStart=/opt/sonatype/nexus/bin/nexus start
ExecStop=/opt/sonatype/nexus/bin/nexus stop
User=nexus
Restart=on-abort

[Install]
WantedBy=multi-user.target

Запуск:

code
Bash
download
content_copy
expand_less
systemctl daemon-reload
systemctl enable --now nexus
Шаг 4: Настройка Proxy-репозитория (через Web-интерфейс)

Откройте http://10.10.1.60:8081. Пароль администратора лежит в /opt/sonatype/sonatype-work/nexus3/admin.password.

Настройте Proxy для Kubernetes:

Repository -> Repositories -> Create repository -> yum (proxy).

Name: k8s-proxy.

Remote storage: https://pkgs.k8s.io/core:/stable:/v1.28/rpm/.

HTTP -> Authentication: не требуется.

Storage: выберите дефолтный (он уже на вашем hdd-raid).

Настройте Proxy для Docker (если нужно):

Create repository -> docker (proxy).

Remote storage: https://registry-1.docker.io.

Docker Index: Use Docker Hub.

Шаг 5: Решение проблемы с "зависанием" (MSS Clamping)

Так как этот LXC сам будет качать пакеты через ваш VPN, на нем тоже нужно применить фикс MTU, иначе он сам будет падать по тайм-ауту при заполнении кэша.

Внутри контейнера nexus-external:

code
Bash
download
content_copy
expand_less
apt install iptables -y
iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
# Сохраните правило (iptables-persistent)
Шаг 6: Переключение нод на новый Nexus

Теперь на всех нодах кластера (Gpu-prox, Chia03, Chia04) меняем конфиг репозитория.

code
Bash
download
content_copy
expand_less
nano /etc/yum.repos.d/kubernetes.repo

Заменяем baseurl:

code
Text
download
content_copy
expand_less
[kubernetes]
name=Kubernetes
baseurl=http://10.10.1.60:8081/repository/k8s-proxy/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key

Результат:
Теперь при запуске dnf update нода мгновенно обращается к вашему LXC по 20Gb-сети. Если пакета нет в кэше, Nexus скачает его сам (с учетом всех настроек стабильности), а все последующие ноды получат его на скорости диска. Ошибки Operation too slow исчезнут.




Эта ошибка возникла по двум причинам:

Конфликт с точкой монтирования: В архиве Nexus есть папка sonatype-work. Так как вы уже примонтировали в это место диск из Proxmox (mp0), tar не может создать или перезаписать эту директорию.

Права доступа (Unprivileged LXC): Скорее всего, ваш контейнер — «непривилегированный» (это стандарт Proxmox для безопасности). В этом случае root внутри контейнера — это не root на хосте, и у него нет прав на запись в примонтированную папку ZFS, пока мы их не дадим на хосте.

Вот как это исправить:

Шаг 1: Исправляем права на хосте (Gpu-prox)

Выйдите из контейнера на хост Proxmox. В непривилегированных контейнерах UID 0 (root) отображается на UID 100000 на хосте. Нам нужно отдать права этому пользователю.

code
Bash
download
content_copy
expand_less
# На хосте gpu-prox
# Даем права на запись для root-пользователя контейнера (100000)
chown -R 100000:100000 /hdd-raid/nexus-data
Шаг 2: Правильная распаковка внутри контейнера

Вернитесь в контейнер (pct enter 500). Мы распакуем архив во временную папку, а потом разнесем файлы по местам.

code
Bash
download
content_copy
expand_less
# Внутри контейнера nexus-ext
cd /opt/sonatype

# Распаковываем во временную папку, чтобы не конфликтовать с точкой монтирования
mkdir -p /tmp/nexus-dist
tar -xf nexus-3.89.1-02-linux-x86_64.tar.gz -C /tmp/nexus-dist/

# Переносим само приложение
mv /tmp/nexus-dist/nexus-3.89.1-02 /opt/sonatype/nexus

# Копируем содержимое дефолтной папки work в вашу чистую точку монтирования
cp -rv /tmp/nexus-dist/sonatype-work/* /opt/sonatype/sonatype-work/

# Удаляем временные файлы
rm -rf /tmp/nexus-dist
Шаг 3: Настройка пользователя и прав (внутри LXC)

Теперь убедимся, что пользователь nexus (которого мы создали ранее) может управлять файлами.

code
Bash
download
content_copy
expand_less
# Уточним UID пользователя nexus внутри контейнера
# (обычно это 1001, если вы создавали его первым после установки)
chown -R nexus:nexus /opt/sonatype/nexus
chown -R nexus:nexus /opt/sonatype/sonatype-work

# Проверим, что в папке sonatype-work появились файлы
ls -la /opt/sonatype/sonatype-work/nexus3
Шаг 4: Проверка версии Java

В вашем выводе tar видно, что Nexus версии 3.89 поставляется со встроенной JDK 21 (nexus-3.89.1-02/jdk/). Это отлично, он будет использовать её сам.

Теперь можно продолжать по инструкции:

Отредактируйте bin/nexus.rc (указать run_as_user="nexus").

Создайте и запустите nexus.service.

Важный момент: При первом запуске Nexus может загружаться от 2 до 5 минут (особенно на HDD-рейде), так как он инициализирует базу данных в sonatype-work.

Проверить, что он «ожил», можно командой:

code
Bash
download
content_copy
expand_less
tail -f /opt/sonatype/sonatype-work/nexus3/log/nexus.log

Как только увидите фразу Started Sonatype Nexus OSS, можно заходить в браузер.