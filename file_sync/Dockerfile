ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:12
FROM $BUILD_FROM

# Копируем аддон
COPY run.sh /run.sh
COPY etc/ /etc/
COPY config.yaml /config.yaml
COPY README.md /README.md

RUN chmod a+x /run.sh \
    && chmod a+x /etc/services.d/ssl_sync/run \
    && chmod a+x /etc/services.d/ssl_sync/finish \
    && chmod a+x /etc/cont-init.d/10-init || true

# Не переопределяем ENTRYPOINT или CMD — базовый образ запускает s6-overlay как PID 1
