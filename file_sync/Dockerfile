# Обязательный ARG с дефолтом для Docker 2025+ (warning уйдёт)
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.2.7

FROM $BUILD_FROM

# Пакеты (bash уже в base, но jq/coreutils/tzdata нужны)
RUN apk add --no-cache \
    curl \
    jq \
    coreutils \
    tzdata

# Копируем файлы
COPY rootfs/ /
COPY run.sh /run.sh

# Права на исполнение
RUN chmod +x /run.sh \
    /etc/cont-init.d/10-init \
    /etc/services.d/file_sync/run \
    /etc/services.d/file_sync/finish

# s6-overlay v3 как PID 1 (стандарт для HAOS 2025.11+)
ENTRYPOINT ["/init"]
