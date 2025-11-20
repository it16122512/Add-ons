#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

log info "SSL Sync starting..."

# ==================== ДИАГНОСТИКА СРЕДЫ ====================
log info "=== ENVIRONMENT DIAGNOSTICS ==="

# Проверка всех смонтированных путей
log info "Checking mounted paths:"
for path in "/config" "/ssl" "/share" "/addon_config" "/backup" "/data" "/addon_configs"; do
    if [ -d "$path" ]; then
        log info "✓ EXISTS: $path"
        # Показываем что внутри
        find "$path" -maxdepth 1 -type d 2>/dev/null | head -5 | while read dir; do
            log info "   - $dir"
        done
    else
        log info "✗ MISSING: $path"
    fi
done

# ==================== КОНФИГУРАЦИЯ ====================
log info "=== CONFIGURATION ==="

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

# ==================== ПОИСК NPM СЕРТИФИКАТОВ ====================
log info "=== SEARCHING FOR NPM CERTIFICATES ==="

# Функция для поиска сертификатов
find_npm_certificates() {
    local rel_path="$1"
    local possible_roots=(
        "/addon_configs"  # ← ОСНОВНОЙ ПУТЬ который найден в логах!
        "/addon_config"
        "/config" 
        "/share"
        "/backup"
    )
    
    for root in "${possible_roots[@]}"; do
        local full_path="${root}/${rel_path}"
        log info "Checking: $full_path"
        if [ -d "$full_path" ]; then
            if [ -f "${full_path}/privkey.pem" ] && [ -f "${full_path}/fullchain.pem" ]; then
                log info "✓ FOUND NPM certificates at: $full_path"
                echo "$full_path"
                return 0
            else
                log info "Directory exists but certificate files missing in $full_path"
            fi
        fi
    done
    
    return 1
}

# Определяем исходный путь
SRC_DIR=$(find_npm_certificates "$SRC_REL")
if [ -z "$SRC_DIR" ]; then
    log error "❌ NPM certificates not found for path: $SRC_REL"
    
    # Расширенный поиск для отладки
    log info "Debug: Searching for any NPM directories..."
    find / -name "*nginxproxymanager*" -type d 2>/dev/null | head -10 | while read dir; do
        log info "   Found NPM dir: $dir"
        if [ -f "${dir}/letsencrypt/live/npm-8/privkey.pem" ]; then
            log info "   ✓ CERTIFICATES FOUND: ${dir}/letsencrypt/live/npm-8"
        fi
    done
    
    exit 1
fi

# Целевой путь
DEST_ROOT="/ssl"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

log info "Resolved paths:"
log info "  Source: $SRC_DIR"
log info "  Destination: $DEST_DIR"

# Проверка сертификатов
log info "Checking certificates in source directory..."
for cert in "privkey.pem" "fullchain.pem"; do
    cert_path="${SRC_DIR}/${cert}"
    if [ -f "$cert_path" ]; then
        size=$(stat -c%s "$cert_path" 2>/dev/null || echo "unknown")
        log info "✓ ${cert}: ${size} bytes"
    else
        log error "❌ Missing: ${cert}"
        log error "Available files in $SRC_DIR:"
        ls -la "$SRC_DIR" 2>/dev/null || log error "Cannot list source directory"
        exit 1
    fi
done

# Создаем целевую директорию
log info "Creating destination directory: $DEST_DIR"
mkdir -p "$DEST_DIR" || {
    log error "❌ Cannot create destination directory: $DEST_DIR"
    exit 1
}

# ==================== ОДИН ЦИКЛ СИНХРОНИЗАЦИИ ====================
log info "=== STARTING SINGLE SYNC CYCLE ==="

CHANGED=false
for cert_file in privkey.pem fullchain.pem; do
    SRC_FILE="$SRC_DIR/$cert_file"
    DEST_FILE="$DEST_DIR/$cert_file"

    if [ -f "$SRC_FILE" ]; then
        if [ ! -f "$DEST_FILE" ] || ! cmp -s "$SRC_FILE" "$DEST_FILE"; then
            log info "Updating $cert_file..."
            if cp -f "$SRC_FILE" "$DEST_FILE"; then
                COPIED_SIZE=$(stat -c%s "$DEST_FILE" 2>/dev/null || echo "unknown")
                log info "✓ Successfully updated $cert_file (${COPIED_SIZE} bytes)"
                CHANGED=true
            else
                log error "❌ Failed to copy $cert_file"
            fi
        else
            log info "No changes for $cert_file"
        fi
    else
        log error "Source file missing: $cert_file"
    fi
done

if [ "$CHANGED" = true ]; then
    log info "✓ Certificate changes detected - restarting Asterisk"
    
    # Перезапуск Asterisk через Supervisor API
    TOKEN=$(bashio::supervisor.token 2>/dev/null || echo "")
    if [ -n "$TOKEN" ]; then
        log info "Sending restart command to Asterisk..."
        if curl -s -f -H "Authorization: Bearer $TOKEN" \
           -X POST "http://supervisor/addons/b35499aa_asterisk/restart" >/dev/null; then
            log info "✓ Asterisk restart command sent successfully"
        else
            log warning "⚠ Could not restart Asterisk (addon might not exist or be unavailable)"
        fi
    else
        log info "ℹ Supervisor token not available"
    fi
else
    log info "No certificate changes detected"
fi

log info "=== SSL SYNC COMPLETED SUCCESSFULLY ==="
log info "Addon will now exit. Next run scheduled via automation."
