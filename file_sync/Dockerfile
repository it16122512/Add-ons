ARG BUILD_FROM
FROM $BUILD_FROM

# Установим пакеты: bash, curl, jq, coreutils, tzdata
# (базовый образ Home Assistant обычно основан на Alpine)
RUN apk add --no-cache bash curl jq coreutils tzdata

# Установим bashio (fallback) — возьмём скрипт из официального репозитория
# если базовый образ уже содержит bashio, эта команда просто перезапишет/обеспечит его наличие.
RUN curl -fsSL https://raw.githubusercontent.com/hassio-addons/bashio/master/bashio \
    -o /usr/bin/bashio && chmod +x /usr/bin/bashio

# Копируем файлы
COPY rootfs/ /
COPY run.sh /run.sh

# Права на исполнение
RUN chmod a+x /run.sh \
    /etc/cont-init.d/10-init \
    /etc/services.d/file_sync/run \
    /etc/services.d/file_sync/finish

# s6-overlay как PID 1 (startup: services)
ENTRYPOINT ["/init"]
