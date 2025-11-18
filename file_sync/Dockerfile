ARG BUILD_FROM
FROM $BUILD_FROM

# Пакеты
RUN apk add --no-cache bash curl rsync inotify-tools openssl

# Bashio (обязательно для 2025.11: config/log/token)
COPY --from=ghcr.io/hassio-addons/bashio:15 /bashio /usr/bin/bashio
RUN chmod a+x /usr/bin/bashio

# Файлы
COPY rootfs/ /
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh \
    /etc/cont-init.d/10-init \
    /etc/services.d/ssl_sync/run \
    /etc/services.d/ssl_sync/finish

# Labels
LABEL \
  io.hass.name="File Sync SSL" \
  io.hass.description="Sync SSL certs from NPM to Asterisk" \
  io.hass.type="addon" \
  io.hass.version="1.3.0"
  
