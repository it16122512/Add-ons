# ARG с дефолтным значением (убирает warning в Docker 2025+)
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.2.7

FROM $BUILD_FROM

# Пакеты: bash уже в base-образе, добавляем только нужное (curl для API, jq для JSON, coreutils/tzdata для утилит)
RUN apk add --no-cache \
    curl \
    jq \
    coreutils \
    tzdata

# Копируем файлы в образ
COPY rootfs/ /
COPY run.sh /run.sh

# Устанавливаем права на исполнение
RUN chmod +x /run.sh \
    /etc/cont-init.d/10-init \
    /etc/services.d/file_sync/run \
    /etc/services.d/file_sync/finish

# s6-overlay v3 как PID 1 (стандарт для HAOS 2025.11+)
ENTRYPOINT ["/init"]
