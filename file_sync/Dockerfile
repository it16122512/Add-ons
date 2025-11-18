# Нет ARG BUILD_FROM — HA auto-detect из config.yaml
FROM $BUILD_FROM

# Установка утилит (diffutils для cmp)
RUN apk add --no-cache bash curl diffutils

# Bashio (попробуйте; если 403 — см. ниже)
COPY --from=ghcr.io/hassio-addons/bashio:15 /bashio /usr/bin/bashio
RUN chmod a+x /usr/bin/bashio

# Копируем rootfs и run.sh (удалите services.d из rootfs/ для consistency)
COPY rootfs/ /
COPY run.sh /run.sh
RUN chmod a+x /run.sh /etc/cont-init.d/10-init

# Основной процесс (PID 1)
CMD ["/run.sh"]
