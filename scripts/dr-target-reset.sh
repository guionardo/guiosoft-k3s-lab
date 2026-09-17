#!/usr/bin/env bash
set -euo pipefail

PROD_HOSTNAME="${DR_PRODUCTION_HOSTNAME:-guiosoft-info}"
PROD_IP="${DR_PRODUCTION_IP:-192.168.88.9}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
STATE_ROOT="${DR_STATE_ROOT:-/var/lib/guiosoft-k3s-dr}"
K3S_DATA_DIR="${DR_K3S_DATA_DIR:-/var/lib/rancher/k3s}"
K3S_CONFIG_DIR="${DR_K3S_CONFIG_DIR:-/etc/rancher/k3s}"
CONFIRM_EXPECTED="reset-dr-target"
HOST="$(hostname -s)"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_safe_absolute_path() {
  local label="$1"
  local path="$2"

  [[ "$path" == /* ]] || fail "$label must be an absolute path: $path"
  case "$path" in
    /|/boot|/dev|/etc|/home|/mnt|/opt|/root|/run|/srv|/tmp|/usr|/var|/var/lib)
      fail "refusing unsafe $label: $path"
      ;;
  esac
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ "$HOST" != "$PROD_HOSTNAME" ]] || fail "refusing reset on production hostname"
ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$PROD_IP" && fail "refusing reset on production IP"
[[ -s "$MARKER_FILE" ]] || fail "DR target marker missing: $MARKER_FILE"
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || fail "invalid DR target marker"
[[ "${DR_TARGET_RESET_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || fail "explicit confirmation required: DR_TARGET_RESET_CONFIRM=$CONFIRM_EXPECTED"

# Validate every destructive root before changing service or filesystem state.
require_safe_absolute_path "K3s data directory" "$K3S_DATA_DIR"
require_safe_absolute_path "K3s config directory" "$K3S_CONFIG_DIR"
require_safe_absolute_path "DR state root" "$STATE_ROOT"
[[ "$STATE_ROOT" == /var/lib/guiosoft-k3s-dr || "$STATE_ROOT" == /var/lib/guiosoft-k3s-dr/* ]] || 
  fail "DR state root must stay below /var/lib/guiosoft-k3s-dr: $STATE_ROOT"
[[ "$K3S_DATA_DIR" == /var/lib/rancher/k3s || "$K3S_DATA_DIR" == /var/lib/rancher/k3s/* ]] ||
  fail "K3s data directory must stay below /var/lib/rancher/k3s: $K3S_DATA_DIR"
[[ "$K3S_CONFIG_DIR" == /etc/rancher/k3s || "$K3S_CONFIG_DIR" == /etc/rancher/k3s/* ]] ||
  fail "K3s config directory must stay below /etc/rancher/k3s: $K3S_CONFIG_DIR"

# Protected DR-host data is intentionally outside all reset roots. Resolve mounts
# read-only and fail if a future configuration ever overlaps them.
for protected in /home/guionardo/data; do
  if [[ -e "$protected" ]]; then
    protected_real="$(readlink -f -- "$protected")"
    for reset_root in "$K3S_DATA_DIR" "$K3S_CONFIG_DIR" "$STATE_ROOT"; do
      reset_real="$(readlink -m -- "$reset_root")"
      case "$protected_real/" in
        "$reset_real"/*) fail "protected path overlaps reset root: $protected -> $reset_root" ;;
      esac
      case "$reset_real/" in
        "$protected_real"/*) fail "reset root overlaps protected path: $reset_root -> $protected" ;;
      esac
    done
  fi
done

systemctl stop k3s 2>/dev/null || true
[[ -x /usr/local/bin/k3s-killall.sh ]] && /usr/local/bin/k3s-killall.sh || true

[[ -x /usr/local/bin/k3s-uninstall.sh ]] && /usr/local/bin/k3s-uninstall.sh || true
rm -rf -- "$K3S_DATA_DIR" "$K3S_CONFIG_DIR"
rm -rf -- /var/tmp/k3s-dr-pv-export /var/tmp/k3s-dr-rehearsal /var/tmp/k3s-dr-live-restore
rm -rf -- /var/lib/guiosoft-k3s-lab/dr-rehearsal

# Recovery checkpoints/timers are per rehearsal. Keeping them makes a later
# orchestrator incorrectly SKIP destructive steps. Preserve reports outside
# STATE_ROOT before reset if they are needed as evidence.
rm -rf -- "$STATE_ROOT/recovery" "$STATE_ROOT/rehearsal-current"

[[ ! -e "$K3S_DATA_DIR" ]] || fail "K3s data dir survived reset"
[[ ! -e "$K3S_CONFIG_DIR" ]] || fail "K3s config dir survived reset"
rm -f -- "$MARKER_FILE"

# Isolation is deliberately removed last, after K3s and recovered workloads are gone.
if nft list table inet dr_isolation >/dev/null 2>&1; then
  nft delete table inet dr_isolation
fi

echo "DR target reset completed: $HOST"
echo "K3s data/config and current recovery checkpoints removed and verified."
echo "Preserved intentionally: Debian, Docker, SSH, Git clone, age identity, encrypted recovery material, historical rehearsal evidence outside current state, and non-K3s disks."
