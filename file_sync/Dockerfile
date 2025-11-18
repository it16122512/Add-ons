ARG BUILD_FROM
FROM $BUILD_FROM

# Установка пакетов
RUN apk add --no-cache bash curl rsync inotify-tools openssl

# Копируем rootfs
COPY rootfs/ /

# Копируем основной скрипт
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh
