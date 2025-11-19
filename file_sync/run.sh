#!/usr/bin/with-contenv bash
set -u

# --- helper: provide minimal fallback for bashio if absent ---
_have_bashio() {
  command -v bashio >/dev/null 2>&1
}

# Simple wrappers: если bashio есть — используем; иначе — fallback printf/echo
_log_info() {
  if _have_bashio; then
    bashio::log.info "$1"
  else
    echo "[INFO] $1"
  fi
}
_log_debug() {
  if _have_bashio; then
    bashio::log.debug "$1"
  else
    echo "[DEBUG] $1"
  fi
}
_log_warn() {
  if _have_bashio; then
    bashio::log.warning "$1"
  else
    echo "[WARN] $1"
  fi
}
_log_err() {
  if _have_bashio; then
    bashio::log.error "$1"
  else
    echo "[ERROR] $1" >&2
  fi
}

# Config read (use bashio if present, else /data/options.json)
if _have_bashio; then
  LOG_LEVEL=$(bashio::config 'log_level' || echo "info")
else
  LOG_LEVEL="info"
fi

_log_info "SSL Sync v1.6.4 starting (log level: ${LOG_LEVEL})..."

# Timezone
if _have_bashio; then
  TZ=$(bashio::config 'timezone' 'UTC')
else
  TZ=$(jq -r '.timezone // "UTC"' /data/options.json 2>/dev/null || echo "UTC")
fi
[ -z "$TZ" ] && TZ="UTC"
export TZ
_log_info "Timezone set to $TZ (local time: $(date))"

# graceful shutdown
cleanup() {
    _log_info "Graceful stop received"
    exit 0
}
trap cleanup TERM INT

# Read main config fields (with defaults)
if _have_bashio; then
  SRC_REL=$(bashio::config 'source_relative_path')
  DEST_REL=$(bashio::config 'dest_relative_path')
  INTERVAL=$(bashio::config 'interval_seconds')
else
  SRC_REL=$(jq -r '.source_relative_path // empty' /data/options.json 2>/dev/null || echo "")
  DEST_REL=$(jq -r '.dest_relative_path // empty' /data/options.json 2>/dev/null || echo "")
  INTERVAL=$(jq -r '.interval_seconds // 300' /data/options.json 2>/dev/null || echo "300")
fi

# Defaults and roots
SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

# Validate critical parameters
if [ -z "$SRC_REL" ] || [ -z "$DEST_REL" ]; then
    _log_err "Source or destination path not configured! (source_relative_path / dest_relative_path)"
    exit 1
fi

# Ensure INTERVAL is numeric and within reasonable bounds
if ! [[ "${INTERVAL}" =~ ^[0-9]+$ ]]; then
  _log_warn "interval_seconds is not numeric, using 300"
  INTERVAL=300
fi

_log_info "Config: ${SRC_DIR} -> ${DEST_DIR} (interval: ${INTERVAL}s)"

# Main loop
while true; do
  _log_info "=== Sync cycle (local: $(date)) ==="

  if [ ! -d "${SRC_DIR}" ]; then
    _log_err "Source directory missing: ${SRC_DIR}"
    _log_debug "Available in /addon_configs:"
    ls -la /addon_configs 2>/dev/null || _log_warn "Cannot access /addon_configs"
    sleep 60
    continue
  fi

  if ! mkdir -p "${DEST_DIR}"; then
    _log_err "Cannot create destination directory: ${DEST_DIR}"
    sleep 60
    continue
  fi

  CHANGED=false
  for f in privkey.pem fullchain.pem; do
    SRC_FILE="${SRC_DIR}/${f}"
    DEST_FILE="${DEST_DIR}/${f}"

    if [ -f "${SRC_FILE}" ]; then
      SRC_SIZE=$(stat -c%s "${SRC_FILE}" 2>/dev/null || echo "0")
      if [ "${SRC_SIZE}" -eq 0 ]; then
        _log_warn "Source file is empty: ${f}"
        continue
      fi

      if ! cmp -s "${SRC_FILE}" "${DEST_FILE}" 2>/dev/null; then
        if cp -f "${SRC_FILE}" "${DEST_FILE}"; then
          _log_info "Updated ${f} (size: ${SRC_SIZE} bytes)"
          CHANGED=true
        else
          _log_err "Failed to copy ${f}"
        fi
      else
        _log_debug "No changes for ${f}"
      fi
    else
      _log_warn "Source file missing: ${f}"
      _log_debug "Available files in source: $(ls -la \"${SRC_DIR}\" 2>/dev/null || echo 'none')"
    fi
  done

  if [ "${CHANGED}" = true ]; then
    if _have_bashio; then
      TOKEN=$(bashio::supervisor_token)
    else
      TOKEN=""
    fi
    ADDON_ID="b35499aa_asterisk"

    if [ -n "${TOKEN}" ]; then
      _log_info "Attempting to restart ${ADDON_ID}..."
      if curl -s -f -H "Authorization: Bearer ${TOKEN}" \
        -X POST "http://supervisor/addons/${ADDON_ID}/restart" >/dev/null 2>&1; then
        _log_info "Successfully restarted ${ADDON_ID}"
      else
        _log_err "Failed to restart ${ADDON_ID} - check if addon exists and is running"
      fi
    else
      _log_err "Cannot get supervisor token - restart skipped"
    fi
  fi

  _log_info "Cycle completed. Sleeping for ${INTERVAL}s..."
  sleep "${INTERVAL}"
done

