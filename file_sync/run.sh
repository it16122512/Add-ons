#!/usr/bin/with-contenv bashio
set -e

# Логирование
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

log info "SSL Sync v1.6.8 starting with DEBUG..."

# ==================== ДЕТАЛЬНАЯ ДИАГНОСТИКА ====================
log info "=== STARTING COMPREHENSIVE DIAGNOSTICS ==="

# 1. Проверка базовых директорий
log info "1. Checking base directories..."
if [ -d "/addon_configs" ]; then
    log info "✓ /addon_configs exists"
    log info "  Permissions: $(ls -ld /addon_configs)"
else
    log error "✗ /addon_configs NOT FOUND!"
    exit 1
fi

if [ -d "/ssl" ]; then
    log info "✓ /ssl exists"
    log info "  Permissions: $(ls -ld /ssl)"
else
    log error "✗ /ssl NOT FOUND!"
    exit 1
fi

# 2. Полный листинг /addon_configs
log info "2. Full contents of /addon_configs:"
ls -la /addon_configs/ 2>/dev/null || log error "Cannot list /addon_configs"

# 3. Поиск всех директорий с nginx/npm в названии
log info "3. Searching for nginx/npm directories..."
find /addon_configs -type d -name "*nginx*" -o -name "*npm*" 2>/dev/null | while read dir; do
    log info "   FOUND DIRECTORY: $dir"
    log info "     Contents: $(ls "$dir" 2>/dev/null | tr '\n' ' ' || echo "empty/cannot access")"
done

# 4. Поиск сертификатов по всему /addon_configs
log info "4. Searching for certificate files in entire /addon_configs..."
cert_files=$(find /addon_configs -name "privkey.pem" -o -name "fullchain.pem" 2>/dev/null)
if [ -n "$cert_files" ]; then
    log info "   Found certificate files:"
    echo "$cert_files" | while read file; do
        if [ -f "$file" ]; then
            size=$(stat -c%s "$file" 2>/dev/null || echo "unknown")
            log info "   ✓ $file (size: ${size} bytes)"
            log info "     Directory: $(dirname "$file")"
            log info "     Full path components:"
            IFS='/' read -ra path_parts <<< "$file"
            for i in "${!path_parts[@]}"; do
                if [ $i -gt 3 ]; then  # Показываем только релевантные части пути
                    log info "       [${i}] ${path_parts[$i]}"
                fi
            done
        fi
    done
else
    log warning "   No certificate files found in /addon_configs"
fi

# 5. Получаем конфигурацию
log info "5. Reading configuration..."
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
INTERVAL=$(bashio::config 'interval_seconds')
TZ=$(bashio::config 'timezone' 'UTC')

export TZ
log info "   Configuration values:"
log info "     source_relative_path: $SRC_REL"
log info "     dest_relative_path: $DEST_REL"
log info "     interval_seconds: $INTERVAL"
log info "     timezone: $TZ"

# 6. Проверка целевых путей
SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

log info "6. Path analysis:"
log info "   Source: $SRC_DIR"
log info "   Destination: $DEST_DIR"

# 7. Детальная проверка исходного пути
log info "7. Detailed source path analysis:"
if [ -d "${SRC_DIR}" ]; then
    log info "   ✓ Source directory EXISTS"
    log info "   Contents of source directory:"
    ls -la "${SRC_DIR}/" 2>/dev/null || log warning "   Cannot list source directory"
    
    # Проверка конкретных файлов
    for f in privkey.pem fullchain.pem; do
        if [ -f "${SRC_DIR}/${f}" ]; then
            size=$(stat -c%s "${SRC_DIR}/${f}" 2>/dev/null || echo "unknown")
            log info "   ✓ $f exists (size: ${size} bytes)"
        else
            log warning "   ✗ $f NOT FOUND in source directory"
        fi
    done
else
    log error "   ✗ Source directory DOES NOT EXIST"
    
    # Поиск ближайших существующих родительских директорий
    log info "   Searching for existing parent directories..."
    current_path="$SRC_ROOT"
    IFS='/' read -ra path_parts <<< "$SRC_REL"
    
    for part in "${path_parts[@]}"; do
        current_path="${current_path}/${part}"
        if [ -d "$current_path" ]; then
            log info "   ✓ Found existing: $current_path"
            log info "     Contents: $(ls "$current_path" 2>/dev/null | tr '\n' ' ' || echo "empty/cannot access")"
        else
            log info "   ✗ Missing: $current_path"
            break
        fi
    done
fi

# 8. Проверка прав доступа
log info "8. Permission check:"
if [ -d "${SRC_DIR}" ]; then
    log info "   Source dir permissions: $(ls -ld "${SRC_DIR}")"
    for f in privkey.pem fullchain.pem; do
        if [ -f "${SRC_DIR}/${f}" ]; then
            log info "   $f permissions: $(ls -l "${SRC_DIR}/${f}")"
        fi
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
        # Здесь можно добавить логику перезапуска сервисов
        # TOKEN=$(bashio::supervisor_token)
        # curl -s -f -H "Authorization: Bearer ${TOKEN}" -X POST "http://supervisor/addons/ADDON_ID/restart"
    else
        log info "No changes detected in this cycle"
    fi

    log info "Sync cycle completed. Sleeping for ${INTERVAL}s..."
    sleep "${INTERVAL}"
done
