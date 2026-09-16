#!/usr/bin/env bash
set -euo pipefail
BUNDLE="${1:-}"; STATE_DIR="${DR_RECOVERY_STATE_DIR:-/var/lib/guiosoft-k3s-dr/recovery}"; [[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }; [[ -n "$BUNDLE" && -d "$BUNDLE" ]] || { echo "usage: DR_RECOVERY_CONFIRM=recover-isolated-k3s $0 /path/to/dr-bundle" >&2; exit 2; }; [[ "${DR_RECOVERY_CONFIRM:-}" == recover-isolated-k3s ]] || { echo "error: set DR_RECOVERY_CONFIRM=recover-isolated-k3s" >&2; exit 1; }; S="$BUNDLE/tooling/scripts"; [[ -x "$S/dr-bundle-verify.sh" ]] || { echo "error: bundle verifier missing" >&2; exit 1; }; bash "$S/dr-bundle-verify.sh" "$BUNDLE"
install -d -m 0700 "$STATE_DIR"; TIMER="$STATE_DIR/timer"; LOG="$STATE_DIR/recovery.log"; [[ -s "$TIMER" ]] || printf 'started_epoch=%s\nstarted_at=%s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TIMER"; exec > >(tee -a "$LOG") 2>&1
step(){ local name="$1"; shift; if [[ -e "$STATE_DIR/$name.done" ]]; then echo "SKIP  $name"; return; fi; echo "BEGIN $name $(date -u +%FT%TZ)"; "$@"; touch "$STATE_DIR/$name.done"; echo "DONE  $name $(date -u +%FT%TZ)"; }
find_one(){ local dir="$1" pattern="$2"; local a; mapfile -t a < <(find "$dir" -maxdepth 1 -type f -name "$pattern" | sort); [[ ${#a[@]} -eq 1 ]] || { echo "error: expected one $pattern in $dir" >&2; exit 1; }; printf '%s' "${a[0]}"; }
CP="$(find_one "$BUNDLE/backups/control-plane" 'k3s-*.tar.gz')"; PV="$(find_one "$BUNDLE/backups/persistent-volumes" 'k3s-persistent-volumes-*.tar.gz')"
# Bootstrap is intentionally outside this transaction. At entry K3s must be a
# clean target with API ready. target-init/isolation are safe, explicit gates.
step target-init bash "$S/dr-target-init.sh"; step isolate bash "$S/dr-network-isolation.sh" enable
# Datastore restore must happen agentless. Refuse rather than silently editing
# config/restarting K3s inside the destructive transaction.
grep -Eq '^[[:space:]]*disable-agent:[[:space:]]*true' /etc/rancher/k3s/config.yaml 2>/dev/null || { echo "error: enable disable-agent:true and restart K3s before continuing" >&2; exit 1; }
step isolated-preflight bash "$S/dr-preflight.sh" isolated; step restore env DR_RESTORE_CONFIRM=restore-isolated-k3s bash "$S/dr-restore-k3s.sh" "$CP"; step neutralize env DR_NEUTRALIZE_CONFIRM=neutralize-isolated-cluster bash "$S/dr-neutralize.sh"; step restored-preflight bash "$S/dr-preflight.sh" restored
step pv-import env DR_PV_IMPORT_CONFIRM=import-isolated-pvs bash "$S/dr-pv-import.sh" "$PV"; step pv-remap env DR_PV_REMAP_CONFIRM=remap-isolated-pvs bash "$S/dr-pv-remap.sh"; step oci-preload bash "$S/dr-oci-preload.sh" "$BUNDLE/oci"
cat <<'EOF'
Automated destructive recovery phase completed. WAN isolation remains active.
Operator checkpoint: remove disable-agent, restart K3s, start only the four approved persistent monitoring workloads, then run dr-preflight.sh full. Do not unsuspend Flux or start cloudflared.
EOF
start="$(awk -F= '$1=="started_epoch"{print $2}' "$TIMER")"; printf 'elapsed_seconds=%s\n' "$(( $(date +%s)-start ))"
