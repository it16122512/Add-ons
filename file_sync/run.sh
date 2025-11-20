#!/usr/bin/with-contenv bashio
set -e

# Логирование с поддержкой уровней
log() {
    local level="info"
    local message="$*"
    
    # Определяем уровень логирования из первого аргумента
    case "$1" in
        error|warning|info|debug)
            level="$1"
            shift
            message="$*"
            ;;
    esac
    
    # Получаем текущий уровень логирования из конфига
    local config_level=$(bashio::config 'log_level' 'info')
    
    # Определяем приоритеты уровней
    local levels=("error" "warning" "info" "debug")
    local config_priority=0
    local message_priority=0
    
    for i in "${!levels[@]}"; do
        if [ "${levels[$i]}" = "$config_level" ]; then
            config_priority=$i
        fi
        if [ "${levels[$i]}" = "$level" ]; then
            message_priority=$i
        fi
    done
    
    # Логируем только если уровень сообщения >= уровня конфига
    if [ $message_priority -le $config_priority ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >&2
    fi
}

# Явные функции для каждого уровня
log_error() { log error "$*"; }
log_warning() { log warning "$*"; }
log_info() { log info "$*"; }
log_debug() { log debug "$*"; }

clear_log() {
    log_info "=== SSL Sync Starting ==="
    log_info "Using Supervisor API method"
    log_debug "Debug logging enabled"
}

clear_log

# Получаем конфигурацию
SRC_ADDON=$(bashio::config 'source_addon_slug')
SRC_REL_PATH=$(bashio::config 'source_cert_path')
DEST_REL=$(bashio::config 'dest_relative_path')
ASTERISK_ADDON=$(bashio::config 'asterisk_addon_slug')
INTERVAL=$(bashio::config 'interval_seconds')
TZ=$(bashio::config 'timezone' 'UTC')
RESTART_ASTERISK=$(bashio::config 'restart_asterisk')

export TZ

# ==================== ПОЛУЧЕНИЕ SUPERVISOR TOKEN ====================

SUPERVISOR_TOKEN=""

# Метод 1: Пытаемся получить токен из переменной окружения
if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
    SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"
    log_info "Using Supervisor token from environment variable"
    log_debug "Token from SUPERVISOR_TOKEN environment variable"

# Метод 2: Пытаемся использовать bashio (если доступен)
elif command -v bashio::supervisor.token >/dev/null 2>&1 && bashio::var.has_value "$(bashio::supervisor.token)"; then
    SUPERVISOR_TOKEN=$(bashio::supervisor.token)
    log_info "Using Supervisor token from bashio"
    log_debug "Token from bashio::supervisor.token"

else
    log_error "Cannot obtain Supervisor token"
    log_error "Available methods:"
    log_error "1. SUPERVISOR_TOKEN environment variable: ${SUPERVISOR_TOKEN:+SET}"
    log_error "2. bashio::supervisor.token: $(command -v bashio::supervisor.token >/dev/null 2>&1 && echo 'AVAILABLE' || echo 'NOT_AVAILABLE')"
    log_error "3. Manual token in configuration"
    exit 1
fi

# Проверяем что токен не пустой
if [ -z "$SUPERVISOR_TOKEN" ]; then
    log_error "Supervisor token is empty"
    exit 1
fi

log_debug "Supervisor token obtained successfully (starts with: ${SUPERVISOR_TOKEN:0:10}...)"

DEST_DIR="/ssl/${DEST_REL}"
mkdir -p "$DEST_DIR"

log_info "Configuration:"
log_info "  Source Addon: $SRC_ADDON"
log_info "  Source Path: $SRC_REL_PATH"
log_info "  Destination: $DEST_DIR"
log_info "  Asterisk Addon: $ASTERISK_ADDON"
log_info "  Interval: ${INTERVAL}s"
log_info "  Restart Asterisk: $RESTART_ASTERISK"
log_info "  Token Source: $([ -n "${SUPERVISOR_TOKEN:-}" ] && echo "environment" || echo "bashio")"

# ==================== ФУНКЦИЯ ПРОВЕРКИ ДОСТУПНОСТИ АДДОНОВ ====================

check_addon_availability() {
    local addon_slug="$1"
    local addon_type="$2"
    
    log_info "Checking if $addon_type addon ($addon_slug) is available..."
    
    if curl -s -f -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons/${addon_slug}/info" >/dev/null 2>&1; then
        log_info "✓ $addon_type addon ($addon_slug) is available"
        return 0
    else
        log_error "✗ $addon_type addon ($addon_slug) not found or inaccessible"
        return 1
    fi
}

# ==================== ФУНКЦИЯ ПРОВЕРКИ ТОКЕНА ====================

validate_token() {
    log_debug "Validating Supervisor token..."
    
    # Пробуем разные эндпоинты для проверки
    local endpoints=("info" "addons" "core/info" "host/info")
    
    for endpoint in "${endpoints[@]}"; do
        if curl -s -f -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/${endpoint}" >/dev/null 2>&1; then
            log_debug "✓ Supervisor token validated via /${endpoint}"
            return 0
        fi
    done
    
    log_error "✗ Supervisor token validation failed on all endpoints"
    return 1
}

# ==================== ФУНКЦИЯ СИНХРОНИЗАЦИИ СЕРТИФИКАТОВ ====================

sync_certificates() {
    local changed=false
    
    # Проверяем доступность файлов перед копированием
    log_debug "Checking certificate files availability..."
    
    for cert_file in "privkey.pem" "fullchain.pem"; do
        if curl -s -f -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/addons/${SRC_ADDON}/files/${SRC_REL_PATH}/${cert_file}" >/dev/null 2>&1; then
            log_debug "✓ $cert_file is available"
        else
            log_warning "✗ $cert_file not available in addon"
            return 1
        fi
    done
    
    # Синхронизируем каждый файл
    for cert_file in "privkey.pem" "fullchain.pem"; do
        local src_url="http://supervisor/addons/${SRC_ADDON}/files/${SRC_REL_PATH}/${cert_file}"
        local dest_file="${DEST_DIR}/${cert_file}"
        local temp_file="${dest_file}.tmp"
        
        log_debug "Processing $cert_file from $src_url"
        
        # Скачиваем во временный файл
        if curl -s -f -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -o "$temp_file" "$src_url"; then
            
            # Проверяем размер файла
            local file_size=$(stat -c%s "$temp_file" 2>/dev/null || echo 0)
            log_debug "Downloaded $cert_file: $file_size bytes"
            
            if [ "$file_size" -lt 100 ]; then
                log_warning "File $cert_file is too small ($file_size bytes), skipping"
                rm -f "$temp_file"
                continue
            fi
            
            # Сравниваем с существующим файлом
            if [ ! -f "$dest_file" ] || ! cmp -s "$temp_file" "$dest_file" 2>/dev/null; then
                if mv -f "$temp_file" "$dest_file"; then
                    log_info "✓ Updated $cert_file ($file_size bytes)"
                    changed=true
                else
                    log_error "Failed to move $cert_file"
                    rm -f "$temp_file"
                fi
            else
                log_debug "No changes for $cert_file"
                rm -f "$temp_file"
            fi
        else
            log_error "Failed to download $cert_file"
            rm -f "$temp_file"
        fi
    done
    
    echo "$changed"
}

# ==================== ФУНКЦИЯ ПЕРЕЗАПУСКА ASTERISK ====================

restart_asterisk() {
    if [ "$RESTART_ASTERISK" = "true" ]; then
        log_info "Attempting to restart Asterisk ($ASTERISK_ADDON)..."
        
        if curl -s -f -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -X POST "http://supervisor/addons/${ASTERISK_ADDON}/restart" >/dev/null 2>&1; then
            log_info "✓ Asterisk ($ASTERISK_ADDON) restart command sent successfully"
        else
            log_warning "⚠ Could not restart Asterisk ($ASTERISK_ADDON) - may be offline or not installed"
        fi
    fi
}

# ==================== ФУНКЦИЯ ПРОВЕРКИ СЕРТИФИКАТОВ ====================

check_certificates() {
    local valid=true
    
    for cert_file in "privkey.pem" "fullchain.pem"; do
        local file="${DEST_DIR}/${cert_file}"
        if [ -f "$file" ]; then
            local size=$(stat -c%s "$file" 2>/dev/null || echo 0)
            if [ "$size" -gt 100 ]; then
                log_debug "✓ $cert_file: $size bytes"
            else
                log_warning "⚠ $cert_file is too small: $size bytes"
                valid=false
            fi
        else
            log_warning "⚠ $cert_file not found"
            valid=false
        fi
    done
    
    [ "$valid" = "true" ]
}

# ==================== ОСНОВНОЙ ЦИКЛ ====================

log_info "=== STARTING MAIN SYNC LOOP ==="

# Проверяем валидность токена
if ! validate_token; then
    log_error "Supervisor token validation failed. Exiting."
    exit 1
fi

# Проверяем доступность обоих аддонов
if ! check_addon_availability "$SRC_ADDON" "NPM Source"; then
    log_error "Source addon not available. Exiting."
    exit 1
fi

if ! check_addon_availability "$ASTERISK_ADDON" "Asterisk"; then
    log_warning "Asterisk addon not available, continuing without restart capability"
    RESTART_ASTERISK=false
fi

CYCLE_COUNT=0
while true; do
    CYCLE_COUNT=$((CYCLE_COUNT + 1))
    
    # Периодическая очистка лога
    if [ $((CYCLE_COUNT % 20)) -eq 0 ]; then
        clear_log
        log_info "Cycle $CYCLE_COUNT - log cleanup"
    fi
    
    log_debug "=== Sync cycle $CYCLE_COUNT started ==="
    
    # Выполняем синхронизацию
    if CHANGED=$(sync_certificates); then
        if [ "$CHANGED" = "true" ]; then
            log_info "✓ Certificate changes detected and applied"
            
            # Проверяем что сертификаты валидны
            if check_certificates; then
                # Перезапускаем Asterisk если нужно и доступен
                restart_asterisk
            else
                log_warning "New certificates appear invalid, skipping Asterisk restart"
            fi
        else
            log_debug "No certificate changes detected in cycle $CYCLE_COUNT"
        fi
    else
        log_error "✗ Sync cycle failed"
    fi
    
    log_debug "Sync cycle $CYCLE_COUNT completed. Sleeping for ${INTERVAL}s..."
    sleep "${INTERVAL}"
done
