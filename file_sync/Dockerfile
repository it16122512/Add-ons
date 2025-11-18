ARG BUILD_FROM
FROM $BUILD_FROM

# Установка зависимостей
RUN apk add --no-cache bash curl rsync inotify-tools openssl

# Bashio (обязательно для 2025.11)
COPY --from=ghcr.io/hassio-addons/bashio:15 /bashio /usr/bin/bashio
RUN chmod a+x /usr/bin/bashio

# Копирование файлов
COPY rootfs/ /
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x \
    /usr/local/bin/run.sh \
    /etc/cont-init.d/10-init \
    /etc/services.d/ssl_sync/run \
    /etc/services.d/ssl_sync/finish

# ВАЖНО: запуск через s6-init
ENTRYPOINT ["/init"]
