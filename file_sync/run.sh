#!/usr/bin/env bash
set -e

# Bashio из base
LOG_LEVEL=$(bashio::config 'log_level')
bashio::log.level "$LOG_LEVEL"
bashio::log.info "SSL Sync v1.7.0 starting (log level: $LOG_LEVEL)..."

# Timezone (для локальных timestamps в log/date)
TZ=$(bashio::config 'timezone')
export TZ
bashio::log.info "Timezone set to $TZ (local time: $(date))"

# Trap TERM от s6 (graceful)
trap 'bashio::log.info "Graceful stop"; exit 0' TERM INT

# Config
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
INTERVAL=$(bashio::config 'interval_seconds')
SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

bashio::log.info "Config: ${SRC_DIR} -> ${DEST_DIR} (interval: ${INTERVAL}s)"

# Daemon loop (long-running для s6)
while true; do
  bashio::log.info "=== Sync cycle (local: $(date)) ==="
  if [ ! -d "${SRC_DIR}" ]; then
    bashio::log.warning "Source missing: ${SRC_DIR}"
    ls -la /addon_configs/ 2>/dev/null || bashio::log.warning "Mount failed"
    sleep 60
    continue
  fi
  mkdir -p "${DEST_DIR}"
  CHANGED=false
  for f in privkey.pem fullchain.pem; do
    SRC_FILE="${SRC_DIR}/${f}"
    DEST_FILE="${DEST_DIR}/${f}"
    if [ -f "${SRC_FILE}" ]; then
      if ! cmp -s "${SRC_FILE}" "${DEST_FILE}" 2>/dev/null; then
        cp -fv "${SRC_FILE}" "${DEST_FILE}"
        bashio::log.info "Updated ${f}"
        CHANGED=true
      fi
    else
      bashio::log.warning "${f} missing"
    fi
  done
  if [ "${CHANGED}" = true ]; then
    TOKEN=$(bashio::supervisor_token)
    ADDON_ID="b35499aa_asterisk"
    if [ -n "${TOKEN}" ] && curl -s -f -H "Authorization: Bearer ${TOKEN}" \
      -X POST "http://supervisor/addons/${ADDON_ID}/restart" >/dev/null 2>&1; then
      bashio::log.info "Restarted ${ADDON_ID}"
    else
      bashio::log.warning "Restart failed"
    fi
  fi
  bashio::log.info "Cycle done; sleep ${INTERVAL}s"
  sleep "${INTERVAL}"
done
