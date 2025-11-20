#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

log info "SSL Sync (oneshot job) starting..."

# ==================== ДИАГНОСТИКА СРЕДЫ ====================
log info "=== ENVIRONMENT DIAGNOSTICS ==="
for path in "/addon_configs" "/ssl"; do
    if [ -d "$path" ]; then
        log info "✓ EXISTS: $path"
        find "$path" -maxdepth 1 -type d 2>/dev/null | head -5 | while read dir; do
            log info "   - $dir"
        done
    else
        log info "✗ MISSING: $path"
    fi
done

# ==================== КОНФИГУРАЦИЯ ====================
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
TZ=$(bashio::config 'timezone' 'UTC')
export TZ

log info "Configuration:"
log info "  source_relative_path: $SRC_REL"
log info "  dest_relative_path: $DEST_REL"
log info "  timezone: $TZ"

# ==================== ПОИСК NPM СЕРТИФИКАТОВ ====================
find_npm_certificates() {
    local rel_path="$1"
    local possible_roots=(
        "/addon_configs"
        "/addon_config"
        "/config"
    )
    for root in "${possible_roots[@]}"; do
        local full_path="${root}/${rel_path}"
        log info "Checking: $full_path"
        if [ -d "$full_path" ] && [ -f "${full_path}/privkey.pem" ] && [ -f "${full_path}/fullchain.pem" ]; then
            log info "✓ FOUND NPM certificates at: $full_path"
            echo "$full_path"
            return 0
        fi
    done
    return 1
}

SRC_DIR=$(find_npm_certificates "$SRC_REL")
if [ -z "$SRC_DIR" ]; then
    log error "❌ NPM certificates not found for path: $SRC_REL"
    log info "Searching for NPM directories..."
    find / -name "*nginxproxymanager*" -type d 2>/dev/null | head -10 | while read dir; do
        log info "   Found: $dir"
        if [ -f "${dir}/letsencrypt/live/npm-8/privkey.pem" ]; then
            log info "   ✓ Certificates in: ${dir}/letsencrypt/live/npm-8"
        fi
    done
    exit 1
fi

DEST_DIR="/ssl/$DEST_REL"
log info "Resolved paths: Source=$SRC_DIR, Destination=$DEST_DIR"

# Проверка сертификатов
for cert in "privkey.pem" "fullchain.pem"; do
    if [ ! -f "${SRC_DIR}/${cert}" ]; then
        log error "❌ Missing certificate: ${cert}"
        ls -la "$SRC_DIR" 2>/dev/null || log error "Cannot list source directory"
        exit 1
    fi
done

mkdir -p "$DEST_DIR" || { log error "❌ Cannot create destination"; exit 1; }

# ==================== ОДНОКРАТНАЯ СИНХРОНИЗАЦИЯ ====================
log info "=== Performing one-time certificate sync ==="

CHANGED=false
for cert_file in privkey.pem fullchain.pem; do
    SRC_FILE="$SRC_DIR/$cert_file"
    DEST_FILE="$DEST_DIR/$cert_file"

    if [ ! -f "$DEST_FILE" ] || ! cmp -s "$SRC_FILE" "$DEST_FILE"; then
        log info "Updating $cert_file..."
        cp -f "$SRC_FILE" "$DEST_FILE"
        size=$(stat -c%s "$DEST_FILE" 2>/dev/null || echo "unknown")
        log info "✓ Updated $cert_file (${size} bytes)"
        CHANGED=true
    else
        log info "No changes for $cert_file"
    fi
done

if [ "$CHANGED" = true ]; then
    log info "✓ Certificates updated — restarting Asterisk addon"
    TOKEN=$(bashio::supervisor.token 2>/dev/null)
    if [ -n "$TOKEN" ]; then
        if curl -s -f -H "Authorization: Bearer $TOKEN" \
           -X POST "http://supervisor/addons/b35499aa_asterisk/restart" >/dev/null; then
            log info "✓ Asterisk restart initiated successfully"
        else
            log warning "⚠ Failed to restart Asterisk (check if addon exists and is installed)"
        fi
    else
        log warning "⚠ Supervisor token unavailable — skipping restart"
    fi
else
    log info "No certificate changes detected"
fi

log info "=== SSL SYNC JOB COMPLETED SUCCESSFULLY ==="
exit 0
