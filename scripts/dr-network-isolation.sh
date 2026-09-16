#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
TABLE="dr_isolation"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
LAN_CIDR="${DR_LAN_CIDR:-192.168.88.0/24}"
POD_CIDR="${DR_POD_CIDR:-10.42.0.0/16}"
SERVICE_CIDR="${DR_SERVICE_CIDR:-10.43.0.0/16}"
HOST="$(hostname -s)"

need() { command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }; }
need nft
need ip

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -s "$MARKER_FILE" ]] || { echo "error: DR target marker missing: $MARKER_FILE" >&2; exit 1; }
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || { echo "error: invalid DR target marker" >&2; exit 1; }
[[ "$HOST" != "$PROD_HOSTNAME" ]] || { echo "error: refusing on production hostname '$HOST'" >&2; exit 1; }
if ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP"; then
  echo "error: refusing on production IP $PROD_IP" >&2
  exit 1
fi

exists() { nft list table inet "$TABLE" >/dev/null 2>&1; }

case "$ACTION" in
  enable)
    if exists; then
      echo "DR WAN isolation already enabled."
      exit 0
    fi
    RULES="$(mktemp)"
    trap 'rm -f "$RULES"' EXIT
    cat >"$RULES" <<EOF
table inet $TABLE {
  chain output {
    type filter hook output priority -50; policy accept;
    oifname "lo" accept
    ct state established,related accept
    ip daddr $LAN_CIDR accept
    ip daddr $POD_CIDR accept
    ip daddr $SERVICE_CIDR accept
    ip daddr 0.0.0.0/0 reject
    ip6 daddr ::/0 reject
  }
  chain forward {
    type filter hook forward priority -50; policy accept;
    ct state established,related accept
    ip daddr $LAN_CIDR accept
    ip daddr $POD_CIDR accept
    ip daddr $SERVICE_CIDR accept
    ip daddr 0.0.0.0/0 reject
    ip6 daddr ::/0 reject
  }
}
EOF
    nft -c -f "$RULES"
    nft -f "$RULES"
    echo "DR WAN isolation enabled. LAN=$LAN_CIDR pods=$POD_CIDR services=$SERVICE_CIDR"
    ;;
  status)
    if exists; then
      echo "DR WAN isolation: ACTIVE"
      nft list table inet "$TABLE"
    else
      echo "DR WAN isolation: INACTIVE"
      exit 1
    fi
    ;;
  disable)
    if exists; then
      nft delete table inet "$TABLE"
      echo "DR WAN isolation disabled."
    else
      echo "DR WAN isolation already disabled."
    fi
    ;;
  *)
    echo "usage: $0 {enable|status|disable}" >&2
    exit 2
    ;;
esac
