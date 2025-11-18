ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache bash curl coreutils

# bashio — обязательно
COPY --from=ghcr.io/hassio-addons/bashio:15 /bashio /usr/bin/bashio
RUN chmod a+x /usr/bin/bashio

COPY rootfs/ /
COPY run.sh /run.sh
RUN chmod a+x /run.sh /etc/cont-init.d/10-init

CMD [ "/run.sh" ]
