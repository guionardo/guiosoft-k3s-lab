#!/usr/bin/env bash
set -euo pipefail

PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
CONFIRM_EXPECTED="reset-dr-target"
HOST="$(hostname -s)"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ "$HOST" != "$PROD_HOSTNAME" ]] || { echo "error: refusing reset on production hostname" >&2; exit 1; }
ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP" && { echo "error: refusing reset on production IP" >&2; exit 1; }
[[ -s "$MARKER_FILE" ]] || { echo "error: DR target marker missing: $MARKER_FILE" >&2; exit 1; }
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || { echo "error: invalid DR target marker" >&2; exit 1; }
[[ "${DR_TARGET_RESET_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || {
  echo "error: explicit confirmation required: DR_TARGET_RESET_CONFIRM=$CONFIRM_EXPECTED" >&2
  exit 1
}

systemctl stop k3s 2>/dev/null || true
[[ -x /usr/local/bin/k3s-killall.sh ]] && /usr/local/bin/k3s-killall.sh || true

if mountpoint -q /mnt/store1/k3s/local-path 2>/dev/null; then
  umount /mnt/store1/k3s/local-path
fi

[[ -x /usr/local/bin/k3s-uninstall.sh ]] && /usr/local/bin/k3s-uninstall.sh || true
rm -rf /var/lib/rancher/k3s /etc/rancher/k3s
rm -rf /var/tmp/k3s-dr-pv-export /var/tmp/k3s-dr-rehearsal /var/tmp/k3s-dr-live-restore
rm -rf /var/lib/guiosoft-k3s-lab/dr-rehearsal
rm -f "$MARKER_FILE"

# Isolation is deliberately removed last, after K3s and recovered workloads are gone.
if nft list table inet dr_isolation >/dev/null 2>&1; then
  nft delete table inet dr_isolation
fi

echo "DR target reset completed: $HOST"
echo "Preserved intentionally: Debian, Docker, SSH, Git clone, age identity, encrypted recovery material and non-K3s disks."
