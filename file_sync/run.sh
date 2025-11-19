#!/usr/bin/env bash
set -e

# Bashio из base
LOG_LEVEL=$(bashio::config 'log_level')
bashio::log.level "$LOG_LEVEL"
bashio::log.info "SSL Sync v1.6.3 starting (log level: $LOG_LEVEL)..."

# Timezone (для локальных timestamps в log/date) - С УЛУЧШЕННОЙ ПРОВЕРКОЙ
TZ=$(bashio::config 'timezone' 'UTC')  # ← ДОБАВИТЬ значение по умолчанию
if [ -z "$TZ" ]; then
    TZ="UTC"
fi
export TZ
bashio::log.info "Timezone set to $TZ (local time: $(date))"

# Trap TERM от s6 (graceful) - УЛУЧШИТЬ обработку
cleanup() {
    bashio::log.info "Graceful stop received"
    exit 0
}
trap cleanup TERM INT

# Config
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
INTERVAL=$(bashio::config 'interval_seconds')
SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

# ← ДОБАВИТЬ проверку критических параметров
if [ -z "$SRC_REL" ] || [ -z "$DEST_REL" ]; then
    bashio::log.error "Source or destination path not configured!"
    exit 1
fi

bashio::log.info "Config: ${SRC_DIR} -> ${DEST_DIR} (interval: ${INTERVAL}s)"

# Daemon loop (long-running для s6)
while true; do
  bashio::log.info "=== Sync cycle (local: $(date)) ==="
  
  # ← УЛУЧШИТЬ проверку source directory
  if [ ! -d "${SRC_DIR}" ]; then
    bashio::log.error "Source directory missing: ${SRC_DIR}"
    bashio::log.debug "Available in /addon_configs:"
    find /addon_configs -maxdepth 2 -type d 2>/dev/null || bashio::log.warning "Cannot access /addon_configs"
    sleep 60
    continue
  fi
  
  # ← УЛУЧШИТЬ создание destination directory
  if ! mkdir -p "${DEST_DIR}"; then
    bashio::log.error "Cannot create destination directory: ${DEST_DIR}"
    sleep 60
    continue
  fi
  
  CHANGED=false
  for f in privkey.pem fullchain.pem; do
    SRC_FILE="${SRC_DIR}/${f}"
    DEST_FILE="${DEST_DIR}/${f}"
    
    # ← ДОБАВИТЬ более детальную проверку файлов
    if [ -f "${SRC_FILE}" ]; then
      SRC_SIZE=$(stat -c%s "${SRC_FILE}" 2>/dev/null || echo "0")
      if [ "$SRC_SIZE" -eq 0 ]; then
        bashio::log.warning "Source file is empty: ${f}"
        continue
      fi
      
      if ! cmp -s "${SRC_FILE}" "${DEST_FILE}" 2>/dev/null; then
        # ← ДОБАВИТЬ проверку успешности копирования
        if cp -f "${SRC_FILE}" "${DEST_FILE}"; then
          bashio::log.info "Updated ${f} (size: ${SRC_SIZE} bytes)"
          CHANGED=true
        else
          bashio::log.error "Failed to copy ${f}"
        fi
      else
        bashio::log.debug "No changes for ${f}"
      fi
    else
      bashio::log.warning "Source file missing: ${f}"
      # ← ДОБАВИТЬ список доступных файлов для отладки
      bashio::log.debug "Available files in source: $(ls -la "${SRC_DIR}" 2>/dev/null || echo 'none')"
    fi
  done
  
  if [ "${CHANGED}" = true ]; then
    TOKEN=$(bashio::supervisor_token)
    ADDON_ID="b35499aa_asterisk"
    
    # ← УЛУЧШИТЬ проверку токена и перезапуск
    if [ -n "${TOKEN}" ]; then
      bashio::log.info "Attempting to restart ${ADDON_ID}..."
      if curl -s -f -H "Authorization: Bearer ${TOKEN}" \
        -X POST "http://supervisor/addons/${ADDON_ID}/restart" >/dev/null 2>&1; then
        bashio::log.info "Successfully restarted ${ADDON_ID}"
      else
        bashio::log.error "Failed to restart ${ADDON_ID} - check if addon exists and is running"
      fi
    else
      bashio::log.error "Cannot get supervisor token - restart skipped"
    fi
  fi
  
  bashio::log.info "Cycle completed. Sleeping for ${INTERVAL}s..."
  sleep "${INTERVAL}"
done
