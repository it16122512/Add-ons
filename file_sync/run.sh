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
    log_info "Using direct filesystem access method"
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

# ==================== ОПРЕДЕЛЕНИЕ ПУТЕЙ ====================

# Источник: файлы NPM addon
SRC_BASE="/mnt/data/supervisor/addons/data/${SRC_ADDON}"
SRC_DIR="${SRC_BASE}/${SRC_REL_PATH}"

# Назначение: папка в общем SSL volume
DEST_DIR="/ssl/${DEST_REL}"

log_info "Configuration:"
log_info "  Source Addon: $SRC_ADDON"
log_info "  Source Path: $SRC_DIR"
log_info "  Destination: $DEST_DIR"
log_info "  Asterisk Addon: $ASTERISK_ADDON"
log_info "  Interval: ${INTERVAL}s"
log_info "  Restart Asterisk: $RESTART_ASTERISK"

# ==================== ФУНКЦИЯ ПРОВЕРКИ ДОСТУПНОСТИ ИСТОЧНИКА ====================

check_source_availability() {
    log_info "Checking if source directory exists..."
    
    if [ -d "$SRC_DIR" ]; then
        log_info "✓ Source directory found: $SRC_DIR"
        
        # Проверяем наличие сертификатных файлов
        local cert_files=("privkey.pem" "fullchain.pem")
        local missing_files=()
        
        for cert_file in "${cert_files[@]}"; do
            if [ -f "${SRC_DIR}/${cert_file}" ]; then
                local file_size=$(stat -c%s "${SRC_DIR}/${cert_file}" 2>/dev/null || echo 0)
                log_debug "✓ $cert_file: $file_size bytes"
            else
                log_warning "✗ $cert_file not found in source"
                missing_files+=("$cert_file")
            fi
        done
        
        if [ ${#missing_files[@]} -eq 0 ]; then
            log_info "✓ All certificate files are available"
            return 0
        else
            log_warning "Missing files: ${missing_files[*]}"
            return 1
        fi
    else
        log_error "✗ Source directory not found: $SRC_DIR"
        log_error "Available addon data directories:"
        find "/mnt/data/supervisor/addons/data" -maxdepth 1 -type d 2>/dev/null | while read dir; do
            if [ "$dir" != "/mnt/data/supervisor/addons/data" ]; then
                log_error "  - $(basename "$dir")"
            fi
        done
        return 1
    fi
}

# ==================== ФУНКЦИЯ СИНХРОНИЗАЦИИ СЕРТИФИКАТОВ ====================

sync_certificates() {
    local changed=false
    
    log_debug "Starting certificate sync..."
    
    # Создаем целевую директорию если не существует
    mkdir -p "$DEST_DIR"
    
    # Синхронизируем каждый файл
    for cert_file in "privkey.pem" "fullchain.pem"; do
        local src_file="${SRC_DIR}/${cert_file}"
        local dest_file="${DEST_DIR}/${cert_file}"
        local temp_file="${dest_file}.tmp"
        
        log_debug "Processing $cert_file"
        
        # Проверяем существование исходного файла
        if [ ! -f "$src_file" ]; then
            log_warning "Source file not found: $src_file"
            continue
        fi
        
        # Проверяем размер исходного файла
        local file_size=$(stat -c%s "$src_file" 2>/dev/null || echo 0)
        if [ "$file_size" -lt 100 ]; then
            log_warning "File $cert_file is too small ($file_size bytes), skipping"
            continue
        fi
        
        # Копируем во временный файл
        if cp "$src_file" "$temp_file"; then
            log_debug "Copied $cert_file: $file_size bytes"
            
            # Сравниваем с существующим файлом
            if [ ! -f "$dest_file" ] || ! cmp -s "$temp_file" "$dest_file" 2>/dev/null; then
                if mv -f "$temp_file" "$dest_file"; then
                    log_info "✓ Updated $cert_file ($file_size bytes)"
                    changed=true
                    
                    # Устанавливаем правильные права
                    chmod 644 "$dest_file"
                else
                    log_error "Failed to move $cert_file"
                    rm -f "$temp_file"
                fi
            else
                log_debug "No changes for $cert_file"
                rm -f "$temp_file"
            fi
        else
            log_error "Failed to copy $cert_file"
            rm -f "$temp_file"
        fi
    done
    
    echo "$changed"
}

# ==================== ФУНКЦИЯ ПЕРЕЗАПУСКА ASTERISK ====================

restart_asterisk() {
    if [ "$RESTART_ASTERISK" = "true" ]; then
        log_info "Attempting to restart Asterisk using Supervisor API..."
        
        # Пробуем получить токен для перезапуска
        local supervisor_token=""
        if [ -r "/mnt/data/supervisor/token" ]; then
            supervisor_token=$(cat "/mnt/data/supervisor/token")
        elif [ -r "/run/s6/container_environment/SUPERVISOR_TOKEN" ]; then
            supervisor_token=$(cat "/run/s6/container_environment/SUPERVISOR_TOKEN")
        fi
        
        if [ -n "$supervisor_token" ]; then
            if curl -s -f -H "Authorization: Bearer ${supervisor_token}" \
                -X POST "http://supervisor/addons/${ASTERISK_ADDON}/restart" >/dev/null 2>&1; then
                log_info "✓ Asterisk ($ASTERISK_ADDON) restart command sent successfully"
            else
                log_warning "⚠ Could not restart Asterisk via API - may be offline"
            fi
        else
            log_warning "⚠ No Supervisor token available for Asterisk restart"
            log_info "Asterisk will need to be restarted manually to use new certificates"
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
            log_warning "⚠ $cert_file not found in destination"
            valid=false
        fi
    done
    
    [ "$valid" = "true" ]
}

# ==================== ОСНОВНОЙ ЦИКЛ ====================

log_info "=== STARTING MAIN SYNC LOOP ==="

# Проверяем доступность источника
if ! check_source_availability; then
    log_error "Source not available. Exiting."
    exit 1
fi

CYCLE_COUNT=0
FIRST_RUN=true

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
        if [ "$CHANGED" = "true" ] || [ "$FIRST_RUN" = "true" ]; then
            if [ "$FIRST_RUN" = "true" ]; then
                log_info "✓ Initial certificate sync completed"
                FIRST_RUN=false
            else
                log_info "✓ Certificate changes detected and applied"
            fi
            
            # Проверяем что сертификаты валидны
            if check_certificates; then
                # Перезапускаем Asterisk если нужно
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
