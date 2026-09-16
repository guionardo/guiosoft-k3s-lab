#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:-}"
STATE_DIR="${DR_RECOVERY_STATE_DIR:-/var/lib/guiosoft-k3s-dr/recovery}"
CONFIRM="${DR_RECOVERY_CONFIRM:-}"
[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "$BUNDLE" && -d "$BUNDLE" ]] || { echo "usage: DR_RECOVERY_CONFIRM=recover-isolated-k3s $0 /path/to/dr-bundle" >&2; exit 2; }
[[ "$CONFIRM" == recover-isolated-k3s ]] || { echo "error: set DR_RECOVERY_CONFIRM=recover-isolated-k3s" >&2; exit 1; }
S="$BUNDLE/tooling/scripts"
[[ -x "$S/dr-bundle-verify.sh" ]] || { echo "error: bundle verifier missing" >&2; exit 1; }
bash "$S/dr-bundle-verify.sh" "$BUNDLE"
install -d -m 0700 "$STATE_DIR"
TIMER="$STATE_DIR/timer"; LOG="$STATE_DIR/recovery.log"
if [[ ! -s "$TIMER" ]]; then printf 'started_epoch=%s\nstarted_at=%s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TIMER"; fi
exec > >(tee -a "$LOG") 2>&1
step(){ local name="$1"; shift; if [[ -e "$STATE_DIR/$name.done" ]]; then echo "SKIP  $name"; return; fi; echo "BEGIN $name $(date -u +%FT%TZ)"; "$@"; touch "$STATE_DIR/$name.done"; echo "DONE  $name $(date -u +%FT%TZ)"; }
find_one(){ local dir="$1" pattern="$2"; local a; mapfile -t a < <(find "$dir" -maxdepth 1 -type f -name "$pattern" | sort); [[ ${#a[@]} -eq 1 ]] || { echo "error: expected one $pattern in $dir" >&2; exit 1; }; printf '%s' "${a[0]}"; }
CP="$(find_one "$BUNDLE/backups/control-plane" 'k3s-*.tar.gz')"; PV="$(find_one "$BUNDLE/backups/persistent-volumes" 'k3s-persistent-volumes-*.tar.gz')"

# The orchestrator intentionally begins after clean-host K3s bootstrap. Network
# isolation and all destructive operations remain guarded by their own scripts.
step target-init bash "$S/dr-target-init.sh"
step isolate bash "$S/dr-network-isolation.sh" enable
step isolated-preflight bash "$S/dr-preflight.sh" isolated
step restore env DR_RESTORE_CONFIRM=restore-isolated-k3s bash "$S/dr-restore-k3s.sh" "$CP"
step neutralize env DR_NEUTRALIZE_CONFIRM=neutralize-isolated-cluster bash "$S/dr-neutralize.sh"
step restored-preflight bash "$S/dr-preflight.sh" restored
step pv-import bash "$S/dr-pv-import.sh" "$PV"
step pv-remap env DR_PV_REMAP_CONFIRM=remap-isolated-pvs bash "$S/dr-pv-remap.sh"
step oci-preload bash "$S/dr-oci-preload.sh" "$BUNDLE/oci"

cat <<'EOF'
Automated destructive recovery phase completed.
The cluster remains WAN-isolated and neutralized.
Next operator checkpoint: enable the K3s agent, start only the approved persistent
workloads, then run: dr-preflight.sh full
EOF
start="$(awk -F= '$1=="started_epoch"{print $2}' "$TIMER")"; now="$(date +%s)"; printf 'elapsed_seconds=%s\n' "$((now-start))"
