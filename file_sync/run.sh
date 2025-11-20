
#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

# ==================== ОЧИСТКА ЖУРНАЛА ====================
clear_log() {
    log info "=== CLEARING LOG ==="
    log info "Starting fresh log session for SSL Sync v1.7.2"
    log info "Previous log entries cleared"
}

# Очищаем журнал при старте
clear_log

log info "SSL Sync starting..."

# ==================== УЛУЧШЕННАЯ ДИАГНОСТИКА ====================
log info "=== ENHANCED DIAGNOSTICS ==="

# 1. Проверка всех смонтированных путей
log info "1. Checking mounted paths:"
for path in "/addon_configs" "/ssl" "/config" "/data"; do
    if [ -d "$path" ]; then
        log info "   ✓ EXISTS: $path"
        log info "     Permissions: $(ls -ld "$path")"
        log info "     First 5 items: $(ls -la "$path" 2>/dev/null | head -6 | tail -5 | tr '\n' '; ' || echo "empty/cannot list")"
    else
        log info "   ✗ MISSING: $path"
    fi
done

# 2. Проверка монтирования
log info "2. Mount details:"
mount | grep -E "(addon|config|ssl|data)" || log info "   No relevant mounts"

# 3. Если /addon_configs существует, проверяем содержимое
if [ -d "/addon_configs" ]; then
    log info "3. /addon_configs contents:"
    ls -la "/addon_configs/" 2>/dev/null | while read line; do
        log info "   $line"
    done || log error "   Cannot list /addon_configs"
    
    # Проверка существования NPM директории
    NPM_PATH="/addon_configs/a0d7b954_nginxproxymanager"
    if [ -d "$NPM_PATH" ]; then
        log info "4. NPM directory found: $NPM_PATH"
        log info "   Contents: $(find "$NPM_PATH" -maxdepth 2 -type d 2>/dev/null | head -10 | tr '\n' ' ' || echo "cannot list")"
    else
        log error "4. NPM directory NOT found: $NPM_PATH"
        log info "   Available in /addon_configs:"
        find "/addon_configs" -maxdepth 1 -type d 2>/dev/null | while read dir; do
            log info "   - $dir"
        done
    fi
else
    log error "3. /addon_configs not available!"
    
    # Проверка через find
    log info "4. Searching for addon_configs anywhere:"
    find / -name "addon_configs" -type d 2>/dev/null | head -5 | while read dir; do
        log info "   Found: $dir"
    done
fi

# ==================== ОСНОВНАЯ КОНФИГУРАЦИЯ ====================
log info "=== MAIN CONFIGURATION ==="

# Получаем конфигурацию
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
INTERVAL=$(bashio::config 'interval_seconds')
TZ=$(bashio::config 'timezone' 'UTC')

export TZ
log info "Configuration:"
log info "  source_relative_path: $SRC_REL"
log info "  dest_relative_path: $DEST_REL"
log info "  interval_seconds: $INTERVAL"
log info "  timezone: $TZ"

# Пути
SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

log info "Full paths:"
log info "  Source: $SRC_DIR"
log info "  Destination: $DEST_DIR"

# Проверка исходного пути
log info "Checking source path..."
if [ -d "${SRC_DIR}" ]; then
    log info "✓ Source directory exists: $SRC_DIR"
    log info "Contents:"
    ls -la "${SRC_DIR}" 2>/dev/null || log error "Cannot list source directory"
    
    # Проверка файлов сертификатов
    for cert_file in "privkey.pem" "fullchain.pem"; do
        if [ -f "${SRC_DIR}/${cert_file}" ]; then
            size=$(stat -c%s "${SRC_DIR}/${cert_file}" 2>/dev/null || echo "unknown")
            log info "✓ Certificate: $cert_file (size: ${size} bytes)"
        else
            log warning "✗ Missing: $cert_file"
        fi
    done
else
    log error "✗ Source directory missing: $SRC_DIR"
    
    # Детальный поиск
    log info "Searching for certificate files in /addon_configs:"
    find "/addon_configs" -name "privkey.pem" -o -name "fullchain.pem" 2>/dev/null | head -10 | while read file; do
        log info "   Found: $file (in: $(dirname "$file"))"
    done
fi

log info "=== DIAGNOSTICS COMPLETE ==="

# ==================== ОСНОВНАЯ ЛОГИКА ====================

# Graceful shutdown
cleanup() {
    log info "Graceful stop received"
    exit 0
}
trap cleanup TERM INT

# Если исходный путь не существует, выходим с ошибкой
if [ ! -d "${SRC_DIR}" ]; then
    log error "FATAL: Source directory not found: ${SRC_DIR}"
    log error "Cannot continue without source certificates"
    exit 1
fi

log info "Starting main sync loop: ${SRC_DIR} -> ${DEST_DIR} (interval: ${INTERVAL}s)"

# Создаем целевую директорию
mkdir -p "${DEST_DIR}" || {
    log error "Cannot create destination directory ${DEST_DIR}"
    exit 1
}

# Главный цикл синхронизации
CYCLE_COUNT=0
while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    
    # Очистка журнала каждые 10 циклов (для предотвращения переполнения)
    if [ $((CYCLE_COUNT % 10)) -eq 0 ]; then
        clear_log
        log info "Cycle ${CYCLE_COUNT} - periodic log cleanup"
    fi
    
    log info "=== Sync cycle ${CYCLE_COUNT} started (local: $(date)) ==="

    # Проверяем что исходная директория всё ещё существует
    if [ ! -d "${SRC_DIR}" ]; then
        log error "Source directory disappeared: ${SRC_DIR}"
        sleep 60
        continue
    fi

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

            # Проверяем, нужно ли копировать
            if [ ! -f "${DEST_FILE}" ] || ! cmp -s "${SRC_FILE}" "${DEST_FILE}" 2>/dev/null; then
                log info "Copying ${f} (size: ${SRC_SIZE} bytes)..."
                if cp -f "${SRC_FILE}" "${DEST_FILE}"; then
                    COPIED_SIZE=$(stat -c%s "${DEST_FILE}" 2>/dev/null || echo "0")
                    log info "✓ Successfully copied ${f} (source: ${SRC_SIZE} bytes, dest: ${COPIED_SIZE} bytes)"
                    CHANGED=true
                else
                    log error "✗ Failed to copy ${f}"
                fi
            else
                log debug "No changes for ${f}"
            fi
        else
            log warning "Source file missing: ${f}"
        fi
    done

    if [ "${CHANGED}" = true ]; then
        log info "✓ Changes detected in certificate files"
        
        # Перезапуск Asterisk
        TOKEN=$(bashio::supervisor_token 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
            log info "Attempting to restart Asterisk..."
            if curl -s -f -H "Authorization: Bearer ${TOKEN}" \
               -X POST "http://supervisor/addons/b35499aa_asterisk/restart" >/dev/null 2>&1; then
                log info "✓ Asterisk restart command sent successfully"
            else
                log warning "⚠ Could not restart Asterisk"
            fi
        else
            log info "ℹ Supervisor token not available"
        fi
    else
        log info "No changes detected in this cycle"
    fi

    log info "Sync cycle ${CYCLE_COUNT} completed. Sleeping for ${INTERVAL}s..."
    sleep "${INTERVAL}"
done
