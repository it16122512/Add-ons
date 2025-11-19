#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log info "SSL Sync v1.6.8 starting..."

# Получаем конфигурацию через bashio
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
INTERVAL=$(bashio::config 'interval_seconds')
TZ=$(bashio::config 'timezone' 'UTC')

# Timezone
export TZ
log info "Timezone set to $TZ (local time: $(date))"

# Graceful shutdown
cleanup() {
    log info "Graceful stop received"
    exit 0
}
trap cleanup TERM INT

# Конфигурация путей
SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

# Проверка обязательных параметров
if [ -z "$SRC_REL" ] || [ -z "$DEST_REL" ]; then
    log error "Source or destination path not configured!"
    exit 1
fi

log info "Config: ${SRC_DIR} -> ${DEST_DIR} (interval: ${INTERVAL}s)"

echo "Creating destination: ${DEST_DIR}"
mkdir -p "${DEST_DIR}" || {
    echo "ERROR: Cannot create destination directory ${DEST_DIR}"
    exit 1
}

# Главный цикл
while true; do
    log info "=== Sync cycle (local: $(date)) ==="

    if [ ! -d "${SRC_DIR}" ]; then
        log warning "Source directory missing: ${SRC_DIR}"
        sleep 60
        continue
    fi

    mkdir -p "${DEST_DIR}" || log warning "Cannot create destination: ${DEST_DIR}"

    CHANGED=false
    for f in privkey.pem fullchain.pem; do
        SRC_FILE="${SRC_DIR}/${f}"
        DEST_FILE="${DEST_DIR}/${f}"

        if [ -f "${SRC_FILE}" ]; then
            SRC_SIZE=$(stat -c%s "${SRC_FILE}" 2>/dev/null || echo "0")
            if [ "$SRC_SIZE" -eq 0 ]; then
                log warning "Source file is empty: ${f}"
                continue
            fi

            if ! cmp -s "${SRC_FILE}" "${DEST_FILE}" 2>/dev/null; then
                if cp -f "${SRC_FILE}" "${DEST_FILE}"; then
                    log info "Updated ${f} (size: ${SRC_SIZE} bytes)"
                    CHANGED=true
                else
                    log error "Failed to copy ${f}"
                fi
            else
                log info "No changes for ${f}"
            fi
        else
            log warning "Source file missing: ${f}"
        fi
    done

    if [ "${CHANGED}" = true ]; then
        log info "Changes detected, consider notifying or restarting services here..."
        # если нужен curl для supervisor API, можно добавить здесь
    fi

    log info "Cycle completed. Sleeping for ${INTERVAL}s..."
    sleep "${INTERVAL}"
done
