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
for path in "/config" "/ssl" "/share" "/addon_config" "/backup" "/data"; do
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

# Graceful shutdown
cleanup() {
    log info "Graceful stop received"
    exit 0
}
trap cleanup TERM INT

# ==================== ПОИСК NPM СЕРТИФИКАТОВ ====================
log info "=== SEARCHING FOR NPM CERTIFICATES ==="

# Пробуем разные пути где может быть NPM
find_npm_certificates() {
    local rel_path="$1"
    local possible_roots=(
        "/addon_config"
        "/config" 
        "/share"
        "/backup"
    )
    
    for root in "${possible_roots[@]}"; do
        local full_path="${root}/${rel_path}"
        log info "Checking: $full_path"
        if [ -d "$full_path" ]; then
            log info "✓ FOUND NPM certificates at: $full_path"
            if [ -f "${full_path}/privkey.pem" ] && [ -f "${full_path}/fullchain.pem" ]; then
                log info "✓ Both certificate files present"
                echo "$full_path"
                return 0
            else
                log warning "Directory exists but certificate files missing"
            fi
        fi
    done
    
    # Расширенный поиск
    log info "Extended search for NPM directories..."
    find / -name "*nginxproxymanager*" -type d 2>/dev/null | head -10 | while read dir; do
        log info "   Potential NPM: $dir"
        if [ -f "${dir}/letsencrypt/live/npm-8/privkey.pem" ]; then
            log info "   ✓ Found certificates in: ${dir}/letsencrypt/live/npm-8"
        fi
    done
    
    return 1
}

# Определяем исходный путь
SRC_DIR=$(find_npm_certificates "$SRC_REL")
if [ -z "$SRC_DIR" ]; then
    log error "❌ NPM certificates not found for path: $SRC_REL"
    log error "Available directories in /addon_config:"
    ls -la "/addon_config" 2>/dev/null || log error "Cannot list /addon_config"
    exit 1
fi

# Целевой путь
DEST_ROOT="/ssl"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

log info "Resolved paths:"
log info "  Source: $SRC_DIR"
log info "  Destination: $DEST_DIR"

# Проверка сертификатов
log info "Checking certificates..."
for cert in "privkey.pem" "fullchain.pem"; do
    if [ -f "${SRC_DIR}/${cert}" ]; then
        size=$(stat -c%s "${SRC_DIR}/${cert}" 2>/dev/null || echo "unknown")
        log info "✓ ${cert}: ${size} bytes"
    else
        log error "❌ Missing: ${cert}"
    fi
done

# Создаем целевую директорию
mkdir -p "$DEST_DIR" || {
    log error "❌ Cannot create destination directory: $DEST_DIR"
    exit 1
}

# ==================== ОСНОВНОЙ ЦИКЛ ====================
log info "=== STARTING MAIN SYNC LOOP ==="

CYCLE_COUNT=0
while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    
    log info "=== Sync cycle $CYCLE_COUNT started ==="

    CHANGED=false
    for cert_file in privkey.pem fullchain.pem; do
        SRC_FILE="$SRC_DIR/$cert_file"
        DEST_FILE="$DEST_DIR/$cert_file"

        if [ -f "$SRC_FILE" ]; then
            if [ ! -f "$DEST_FILE" ] || ! cmp -s "$SRC_FILE" "$DEST_FILE"; then
                log info "Updating $cert_file..."
                if cp -f "$SRC_FILE" "$DEST_FILE"; then
                    log info "✓ Successfully updated $cert_file"
                    CHANGED=true
                else
                    log error "❌ Failed to copy $cert_file"
                fi
            else
                log info "No changes for $cert_file"
            fi
        else
            log warning "Source file missing: $cert_file"
        fi
    done

    if [ "$CHANGED" = true ]; then
        log info "✓ Certificate changes detected - restarting Asterisk"
        
        # Перезапуск Asterisk через Supervisor API
        TOKEN=$(bashio::supervisor.token 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
            if curl -s -f -H "Authorization: Bearer $TOKEN" \
               -X POST "http://supervisor/addons/b35499aa_asterisk/restart" >/dev/null; then
                log info "✓ Asterisk restart command sent"
            else
                log warning "⚠ Could not restart Asterisk"
            fi
        else
            log info "ℹ Supervisor token not available"
        fi
    fi

    log info "Cycle $CYCLE_COUNT completed. Sleeping for ${INTERVAL}s..."
    sleep "$INTERVAL"
done
