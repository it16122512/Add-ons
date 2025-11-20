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

# Возможные расположения данных аддонов в HAOS
POSSIBLE_BASE_PATHS=(
    "/mnt/data/supervisor/addons/data/${SRC_ADDON}"
    "/mnt/data/addons/data/${SRC_ADDON}"
    "/data/${SRC_ADDON}"
    "/usr/share/hassio/addons/data/${SRC_ADDON}"
    "/addons/${SRC_ADDON}"
)

# Назначение: папка в общем SSL volume
DEST_DIR="/ssl/${DEST_REL}"

log_info "Configuration:"
log_info "  Source Addon: $SRC_ADDON"
log_info "  Source Relative Path: $SRC_REL_PATH"
log_info "  Destination: $DEST_DIR"
log_info "  Asterisk Addon: $ASTERISK_ADDON"
log_info "  Interval: ${INTERVAL}s"
log_info "  Restart Asterisk: $RESTART_ASTERISK"

# ==================== ФУНКЦИЯ ПОИСКА ПУТИ ИСТОЧНИКА ====================

find_source_path() {
    log_info "Searching for source directory..."
    
    local found_path=""
    
    for base_path in "${POSSIBLE_BASE_PATHS[@]}"; do
        local full_path="${base_path}/${SRC_REL_PATH}"
        log_debug "Checking: $full_path"
        
        if [ -d "$full_path" ]; then
            found_path="$full_path"
            log_info "✓ Found source directory: $found_path"
            break
        fi
    done
    
    if [ -z "$found_path" ]; then
        log_error "✗ Source directory not found in any location"
        log_error "Searched in:"
        for base_path in "${POSSIBLE_BASE_PATHS[@]}"; do
            local full_path="${base_path}/${SRC_REL_PATH}"
            log_error "  - $full_path"
        done
        
        # Покажем какие аддоны вообще доступны
        log_error "Available addon data directories:"
        local available_dirs=()
        
        # Проверяем основные корневые директории
        local root_paths=(
            "/mnt/data/supervisor/addons/data"
            "/mnt/data/addons/data" 
            "/data"
            "/usr/share/hassio/addons/data"
            "/addons"
        )
        
        for root_path in "${root_paths[@]}"; do
            if [ -d "$root_path" ]; then
                log_error "  In $root_path:"
                if find "$root_path" -maxdepth 1 -type d 2>/dev/null | head -10 | while read dir; do
                    if [ "$dir" != "$root_path" ] && [ -n "$dir" ]; then
                        log_error "    - $(basename "$dir")"
                    fi
                done; then
                    :
                else
                    log_error "    (cannot list or empty)"
                fi
            fi
        done
    fi
    
    echo "$found_path"
}

# ==================== ФУНКЦИЯ ПРОВЕРКИ ДОСТУПНОСТИ ИСТОЧНИКА ====================

check_source_availability() {
    local src_dir="$1"
    
    log_info "Checking source directory: $src_dir"
    
    if [ -d "$src_dir" ]; then
        log_info "✓ Source directory exists"
        
        # Проверяем наличие сертификатных файлов
        local cert_files=("privkey.pem" "fullchain.pem")
        local missing_files=()
        
        for cert_file in "${cert_files[@]}"; do
            if [ -f "${src_dir}/${cert_file}" ]; then
                local file_size=$(stat -c%s "${src_dir}/${cert_file}" 2>/dev/null || echo 0)
                log_info "✓ $cert_file: $file_size bytes"
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
        log_error "✗ Source directory not accessible"
        return 1
    fi
}

# ==================== ФУНКЦИЯ СИНХРОНИЗАЦИИ СЕРТИФИКАТОВ ====================

sync_certificates() {
    local src_dir="$1"
    local changed=false
    
    log_debug "Starting certificate sync from: $src_dir"
    
    # Создаем целевую директорию если не существует
    mkdir -p "$DEST_DIR"
    
    # Синхронизируем каждый файл
    for cert_file in "privkey.pem" "fullchain.pem"; do
        local src_file="${src_dir}/${cert_file}"
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
        local token_paths=(
            "/mnt/data/supervisor/token"
            "/run/s6/container_environment/SUPERVISOR_TOKEN"
            "/etc/SUPERVISOR_TOKEN"
        )
        
        for token_path in "${token_paths[@]}"; do
            if [ -r "$token_path" ]; then
                supervisor_token=$(cat "$token_path")
                log_debug "Found token at: $token_path"
                break
            fi
        done
        
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

# Ищем путь к исходным файлам
SRC_DIR=$(find_source_path)
if [ -z "$SRC_DIR" ]; then
    log_error "Source path not found. Exiting."
    exit 1
fi

# Проверяем доступность источника
if ! check_source_availability "$SRC_DIR"; then
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
    if CHANGED=$(sync_certificates "$SRC_DIR"); then
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
