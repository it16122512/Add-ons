ARG BUILD_FROM
FROM $BUILD_FROM

# Установка утилит
RUN apk add --no-cache bash curl coreutils

# Bashio для HA add-on
COPY --from=ghcr.io/hassio-addons/bashio:15 /bashio /usr/bin/bashio
RUN chmod a+x /usr/bin/bashio

# Копируем rootfs и run.sh
COPY rootfs/ /
COPY run.sh /run.sh
RUN chmod a+x /run.sh /etc/cont-init.d/10-init /etc/services.d/ssl_sync/run /etc/services.d/ssl_sync/finish

# Основной процесс
CMD [ "/run.sh" ]
