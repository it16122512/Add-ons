#!/bin/sh
set -e

SRC_REL="${OPTION_SOURCE_RELATIVE_PATH:-a0d7b954_nginxproxymanager/letsencrypt/live/npm-8}"
DEST_REL="${OPTION_DEST_RELATIVE_PATH:-nginxproxymanager/live/npm-1}"
INTERVAL="${OPTION_INTERVAL_SECONDS:-300}"

SRC_ROOT="/addon_configs"
DEST_ROOT="/ssl"

SRC_DIR="$SRC_ROOT/$SRC_REL"
DEST_DIR="$DEST_ROOT/$DEST_REL"

echo "=== SSL Sync: $SRC_DIR -> $DEST_DIR ==="

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: Source folder not found: $SRC_DIR"
  ls -la /addon_configs/ 2>/dev/null || echo "/addon_configs not mounted"
  exit 1
fi

mkdir -p "$DEST_DIR"

# copy only if file exists
for f in privkey.pem fullchain.pem; do
  if [ -f "$SRC_DIR/$f" ]; then
    cp -fv "$SRC_DIR/$f" "$DEST_DIR/"
  else
    echo "WARN: $f not found in $SRC_DIR"
  fi
done

# Restart Asterisk via Supervisor (if available)
if [ -n "${SUPERVISOR_TOKEN}" ]; then
  ADDON_ID="b35499aa_asterisk"
  echo "Calling Supervisor API to restart $ADDON_ID"
  if curl -s -f -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -X POST "http://supervisor/addons/${ADDON_ID}/restart"; then
    echo "Supervisor: restart requested"
  else
    echo "Supervisor: restart failed (non-fatal)"
  fi
else
  echo "SUPERVISOR_TOKEN not provided — skipping Supervisor API call"
fi

echo "Sync done"
exit 0
