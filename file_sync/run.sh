#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

log info "=== SSL Sync starting... ==="

# ==================== РАСШИРЕННАЯ ДИАГНОСТИКА МОНТИРОВАНИЯ ====================
log info "=== EXTENDED MOUNT DIAGNOSTICS ==="

# 1. Проверка ВСЕХ директорий в корне
log info "1. All root directories:"
ls -la / 2>/dev/null | while read line; do
    log info "   $line"
done

# 2. Проверка конкретных путей с разными вариантами
log info "2. Checking specific paths:"
for path in "/addon_configs" "/addon_config" "/config" "/data" "/ssl" "/share" "/media" "/backup"; do
    if [ -d "$path" ]; then
        log info "   ✓ EXISTS: $path"
        log info "     First 3 items: $(ls "$path" 2>/dev/null | head -3 | tr '\n' ' ' || echo "empty")"
    else
        log info "   ✗ MISSING: $path"
    fi
done

# 3. Проверка монтирования из /proc/mounts
log info "3. Current mounts:"
mount | grep -E "(addon|config|data|ssl)" || log info "   No relevant mounts found"

# 4. Проверка через /proc/mounts
log info "4. /proc/mounts entries:"
grep -E "(addon|config|data|ssl)" /proc/mounts || log info "   No entries found"

# 5. Проверка через environment
log info "5. Environment variables:"
env | grep -i "addon\|config\|data" || log info "   No relevant env vars"

# 6. КРИТИЧЕСКАЯ ПРОВЕРКА - если /addon_configs нет, ищем альтернативы
if [ ! -d "/addon_configs" ]; then
    log error "CRITICAL: /addon_configs not found!"
    
    # Поиск альтернативных путей
    log info "6. Searching for alternative paths..."
    find / -maxdepth 2 -type d -name "*a0d7b954_nginxproxymanager*" -o -name "*addon*" 2>/dev/null | head -10 | while read dir; do
        log info "   FOUND: $dir"
    done
    
    # Проверка стандартных путей HA
    log info "7. Checking HA standard paths:"
    for base in "/config" "/data" "/share" "/media"; do
        if [ -d "$base" ]; then
            log info "   Checking $base/addon_configs..."
            if [ -d "$base/addon_configs" ]; then
                log info "   ✓ FOUND: $base/addon_configs"
                # Создаем симлинк
                ln -sf "$base/addon_configs" /addon_configs 2>/dev/null && log info "   Symlink created: /addon_configs -> $base/addon_configs"
            fi
        fi
    done
    
    # Финальная проверка
    if [ ! -d "/addon_configs" ]; then
        log error "FINAL: /addon_configs still not available after search"
        log error "Available directories in root:"
        ls -la / 2>/dev/null | grep "^d" || log error "Cannot list root"
        exit 1
    fi
fi

log info "✓ /addon_configs is available"

# Проверка /ssl
if [ ! -d "/ssl" ]; then
    log error "CRITICAL: /ssl not found!"
    exit 1
fi

log info "✓ /ssl is available"

# ==================== ОСНОВНАЯ ДИАГНОСТИКА NPM ====================
log info "=== NPM CONFIGURATION DIAGNOSTICS ==="

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

# Конфигурация путей
SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

log info "Full paths:"
log info "  Source: $SRC_DIR"
log info "  Destination: $DEST_DIR"

# Проверка существования исходного пути
log info "Checking source path..."
if [ -d "${SRC_DIR}" ]; then
    log info "✓ Source directory exists: $SRC_DIR"
    log info "Contents: $(ls -la "${SRC_DIR}" 2>/dev/null | head -10 || echo "cannot list")"
    
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
    log info "Available directories in /addon_configs:"
    ls -la "/addon_configs/" 2>/dev/null || log error "Cannot access /addon_configs"
    
    # Поиск npm-8 в других местах
    log info "Searching for npm-8 in other locations..."
    find "/addon_configs" -type d -name "npm-8" 2>/dev/null | while read dir; do
        log info "   FOUND npm-8: $dir"
        log info "     Parent: $(dirname "$dir")"
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

# Проверка обязательных параметров
if [ -z "$SRC_REL" ] || [ -z "$DEST_REL" ]; then
    log error "Source or destination path not configured!"
    exit 1
fi

log info "Starting main sync loop: ${SRC_DIR} -> ${DEST_DIR} (interval: ${INTERVAL}s)"

# Создаем целевую директорию
mkdir -p "${DEST_DIR}" || {
    log error "Cannot create destination directory ${DEST_DIR}"
    exit 1
}

# Главный цикл синхронизации
while true; do
    log info "=== Sync cycle started (local: $(date)) ==="

    if [ ! -d "${SRC_DIR}" ]; then
        log error "CRITICAL: Source directory still missing: ${SRC_DIR}"
        log info "Available content in /addon_configs:"
        find "/addon_configs" -name "*nginx*" -o -name "*npm*" 2>/dev/null | head -10 | while read item; do
            log info "   Found: $item"
        done
        log info "Retrying in 60 seconds..."
        sleep 60
        continue
    fi

    # Создаем/проверяем целевую директорию
    mkdir -p "${DEST_DIR}" || {
        log error "Cannot create destination directory: ${DEST_DIR}"
        sleep "${INTERVAL}"
        continue
    }

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
        
        # Автоматический перезапуск Asterisk
        TOKEN=$(bashio::supervisor_token 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
            log info "Attempting to restart Asterisk..."
            if curl -s -f -H "Authorization: Bearer ${TOKEN}" \
               -X POST "http://supervisor/addons/b35499aa_asterisk/restart" >/dev/null 2>&1; then
                log info "✓ Asterisk restart command sent successfully"
            else
                log warning "⚠ Could not restart Asterisk (may be normal if token unavailable)"
            fi
        else
            log info "ℹ Supervisor token not available (running in debug?)"
        fi
    else
        log info "No changes detected in this cycle"
    fi

    log info "Sync cycle completed. Sleeping for ${INTERVAL}s..."
    sleep "${INTERVAL}"
done
