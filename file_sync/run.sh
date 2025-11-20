#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"
}

log info "SSL Sync starting..."

# Конфигурация
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
INTERVAL=$(bashio::config 'interval_seconds')
TZ=$(bashio::config 'timezone' 'UTC')
RESTART_ASTERISK=$(bashio::config 'restart_asterisk' 'true')

export TZ

log info "Config: ${SRC_REL} -> ${DEST_REL} (interval: ${INTERVAL}s)"

# Пути
SRC_DIR="/addon_configs/${SRC_REL}"
DEST_DIR="/ssl/${DEST_REL}"

# Проверка исходного пути
if [ ! -d "${SRC_DIR}" ]; then
    log error "Source directory not found: ${SRC_DIR}"
    exit 1
fi

# Создание целевой директории
mkdir -p "${DEST_DIR}"

log info "Starting sync loop..."

# Главный цикл
while true; do
    CHANGED=false
    
    for cert_file in privkey.pem fullchain.pem; do
        SRC_FILE="${SRC_DIR}/${cert_file}"
        DEST_FILE="${DEST_DIR}/${cert_file}"
        
        if [ -f "${SRC_FILE}" ]; then
            if [ ! -f "${DEST_FILE}" ] || ! cmp -s "${SRC_FILE}" "${DEST_FILE}"; then
                if cp -f "${SRC_FILE}" "${DEST_FILE}"; then
                    log info "Updated ${cert_file}"
                    CHANGED=true
                else
                    log error "Failed to copy ${cert_file}"
                fi
            fi
        else
            log warning "Source file missing: ${cert_file}"
        fi
    done

    # Перезапуск Asterisk при изменениях
    if [ "${CHANGED}" = true ] && [ "${RESTART_ASTERISK}" = "true" ]; then
        log info "Restarting Asterisk..."
        TOKEN=$(bashio::supervisor.token)
        if [ -n "${TOKEN}" ]; then
            curl -s -f -H "Authorization: Bearer ${TOKEN}" \
                 -X POST "http://supervisor/addons/b35499aa_asterisk/restart" >/dev/null && \
            log info "Asterisk restart sent" || log warning "Asterisk restart failed"
        else
            log warning "Supervisor token unavailable"
        fi
    fi

    sleep "${INTERVAL}"
done
