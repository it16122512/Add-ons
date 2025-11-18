ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM $BUILD_FROM

# Установка пакетов
RUN apk add --no-cache bash curl rsync inotify-tools openssl

# Копируем rootfs
COPY rootfs/ /

# Копируем основной скрипт
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh
