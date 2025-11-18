#!/usr/bin/with-contenv bash
set -e

# Bashio setup
bashio::log.level "INFO"
bashio::log.info "SSL Sync starting..."

# Graceful shutdown (s6 TERM)
trap 'bashio::log.info "Stopping gracefully"; exit 0' TERM INT

# Config via bashio (надежнее OPTION_*)
SRC_REL=$(bashio::config 'source_relative_path')
DEST_REL=$(bashio::config 'dest_relative_path')
INTERVAL=$(bashio::config 'interval_seconds')

SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"
SRC_DIR="${SRC_ROOT}/${SRC_REL}"
DEST_DIR="${DEST_ROOT}/${DEST_REL}"

bashio::log.info "Sync config: ${SRC_DIR} -> ${DEST_DIR} (every ${INTERVAL}s)"

# Цикл: sync + sleep (long-running)
while true; do
  bashio::log.info "=== Sync cycle start ==="

  if [ ! -d "${SRC_DIR}" ]; then
    bashio::log.warning "Source missing: ${SRC_DIR}"
    ls -la /addon_configs/ 2>/dev/null || bashio::log.warning "/addon_configs not mounted"
    sleep 60  # Retry на ошибке
    continue
  fi

  mkdir -p "${DEST_DIR}"
  CHANGED=false

  # Sync certs с diff-check
  for f in privkey.pem fullchain.pem; do
    SRC_FILE="${SRC_DIR}/${f}"
    DEST_FILE="${DEST_DIR}/${f}"
    if [ -f "${SRC_FILE}" ]; then
      if ! cmp -s "${SRC_FILE}" "${DEST_FILE}" 2>/dev/null; then
        cp -fv "${SRC_FILE}" "${DEST_FILE}"
        bashio::log.info "Copied ${f} (changed)"
        CHANGED=true
      else
        bashio::log.debug "${f} unchanged"
      fi
    else
      bashio::log.warning "${f} missing in source"
    fi
  done

  # Restart if changed
  if [ "${CHANGED}" = true ]; then
    TOKEN=$(bashio::supervisor_token)
    ADDON_ID="b35499aa_asterisk"
    if [ -n "${TOKEN}" ] && curl -s -f -H "Authorization: Bearer ${TOKEN}" \
      -X POST "http://supervisor/addons/${ADDON_ID}/restart" >/dev/null 2>&1; then
      bashio::log.info "Restarted ${ADDON_ID}"
    else
      bashio::log.warning "Restart failed (non-fatal)"
    fi
  fi

  bashio::log.info "Cycle done; sleep ${INTERVAL}s"
  sleep "${INTERVAL}"
done
