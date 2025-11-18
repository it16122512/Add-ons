ARG BUILD_FROM
FROM $BUILD_FROM

# Установка зависимостей
RUN apk add --no-cache bash curl rsync inotify-tools openssl

# Bashio
COPY --from=ghcr.io/hassio-addons/bashio:15 /bashio /usr/bin/bashio
RUN chmod a+x /usr/bin/bashio

# Копирование
COPY rootfs/ /
COPY run.sh /usr/local/bin/run.sh

# Права
RUN chmod +x \
    /usr/local/bin/run.sh \
    /etc/cont-init.d/10-init \
    /etc/services.d/ssl_sync/run \
    /etc/services.d/ssl_sync/finish

# Запуск через s6-init как PID 1
ENTRYPOINT ["/init"]
