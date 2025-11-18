FROM alpine:3.20

# Версии
ARG S6_OVERLAY_VERSION=v3.1.6.2

# Установка зависимостей
RUN apk add --no-cache bash curl rsync inotify-tools openssl

# Установка s6-overlay
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp/

RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz && \
    rm -f /tmp/*.tar.xz

# Копируем rootfs полностью в контейнер
COPY rootfs/ /

# Скрипт запуска
COPY run.sh /root/

RUN chmod +x /root/run.sh

ENTRYPOINT ["/init"]

