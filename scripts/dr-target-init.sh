#!/usr/bin/env bash
set -euo pipefail

MARKER_DIR="/etc/guiosoft-k3s-lab"
MARKER_FILE="$MARKER_DIR/dr-rehearsal-target"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
HOST="$(hostname -s)"

[[ ${EUID} -eq 0 ]] || { echo "error: this target initialization must run as root" >&2; exit 1; }

if [[ "$HOST" == "$PROD_HOSTNAME" ]]; then
  echo "error: refusing to mark production hostname '$HOST' as a DR rehearsal target" >&2
  exit 1
fi

if ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP"; then
  echo "error: refusing to mark a host that owns production IP $PROD_IP as a DR rehearsal target" >&2
  exit 1
fi

install -d -o root -g root -m 0700 "$MARKER_DIR"
{
  echo "mode=isolated-dr-rehearsal"
  echo "hostname=$HOST"
  echo "created_at=$(date --iso-8601=seconds)"
} > "$MARKER_FILE"
chmod 0600 "$MARKER_FILE"

echo "DR rehearsal target marker created: $MARKER_FILE"
echo "Host: $HOST"
echo "Production hostname/IP guards passed."
