#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

# Очистка журнала
clear_log() {
    log info "=== CLEARING LOG ==="
    log info "Starting fresh log session for SSL Sync v2.1.0"
    log info "Previous log entries cleared"
}

clear_log
log info "SSL Sync starting..."

# ==================== ПОЛУЧЕНИЕ КОНФИГУРАЦИИ ====================
SRC_REL=$(bashio::config 'source_relative_path' 2>/dev/null || echo "letsencrypt/live/npm-8")
DEST_REL=$(bashio::config 'dest_relative_path' 2>/dev/null || echo "nginxproxymanager/live/npm-1")
INTERVAL=$(bashio::config 'interval_seconds' 2>/dev/null || echo "300")
TZ=$(bashio::config 'timezone' 2>/dev/null || echo "UTC")
export TZ

log info "Configuration:"
log info "  source_relative_path: $SRC_REL"
log info "  dest_relative_path: $DEST_REL"
log info "  interval_seconds: $INTERVAL"
log info "  timezone: $TZ"

# ==================== ПУТИ ====================
SRC_ROOT="/addon_config"  # используем addon_config
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

log info "Full paths:"
log info "  Source: $SRC_DIR"
log info "  Destination: $DEST_DIR"

# Проверка исходного пути
if [ ! -d "${SRC_DIR}" ]; then
    log error "✗ Source directory missing: $SRC_DIR"
    exit 1
fi

mkdir -p "${DEST_DIR}" || {
    log error "Cannot create destination directory ${DEST_DIR}"
    exit 1
}

# ==================== ЦИКЛ СИНХРОНИЗАЦИИ ====================
CYCLE_COUNT=0
while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    log info "=== Sync cycle ${CYCLE_COUNT} started (local: $(date)) ==="

    CHANGED=false
    for f in privkey.pem fullchain.pem; do
        SRC_FILE="${SRC_DIR}/${f}"
        DEST_FILE="${DEST_DIR}/${f}"

        if [ -f "${SRC_FILE}" ]; then
            if [ ! -f "${DEST_FILE}" ] || ! cmp -s "${SRC_FILE}" "${DEST_FILE}" 2>/dev/null; then
                log info "Copying ${f}..."
                cp -f "${SRC_FILE}" "${DEST_FILE}" && CHANGED=true
            else
                log info "No changes for ${f}"
            fi
        else
            log warning "Source file missing: ${f}"
        fi
    done

    if [ "${CHANGED}" = true ]; then
        log info "Changes detected, attempting to restart Asterisk..."
        TOKEN=$(bashio::supervisor_token 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
            curl -s -f -H "Authorization: Bearer ${TOKEN}" \
                 -X POST "http://supervisor/addons/b35499aa_asterisk/restart" >/dev/null 2>&1 \
                 && log info "Asterisk restart command sent successfully"
        fi
    fi

    log info "Sync cycle ${CYCLE_COUNT} completed. Sleeping ${INTERVAL}s..."
    sleep "${INTERVAL}"
done

