ARG BUILD_FROM
FROM $BUILD_FROM

# Устанавливаем пакеты
RUN apk add --no-cache bash curl jq coreutils tzdata

# Копируем файлы
COPY rootfs/ /
COPY run.sh /run.sh

# Права на исполнение
RUN chmod a+x /run.sh \
    /etc/cont-init.d/10-init \
    /etc/services.d/file_sync/run \
    /etc/services.d/file_sync/finish

# s6-overlay как PID 1
ENTRYPOINT ["/init"]
