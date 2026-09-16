#!/usr/bin/env bash
set -euo pipefail
RECOVERY_STATE_DIR="${DR_RECOVERY_STATE_DIR:-/var/lib/guiosoft-k3s-dr/recovery}"
REHEARSAL_STATE_DIR="${DR_REHEARSAL_STATE_DIR:-/var/lib/guiosoft-k3s-dr/rehearsal-current}"
BUNDLE="${1:-}"
OUT="${2:-$REHEARSAL_STATE_DIR/rehearsal-report.txt}"
DEFAULT_BASELINE="${DR_RTO_BASELINE_SECONDS:-4029}"
[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "$BUNDLE" && -d "$BUNDLE" ]] || { echo "usage: $0 /path/to/dr-bundle [report-file]" >&2; exit 2; }
S="$BUNDLE/tooling/scripts"
[[ -x "$S/dr-preflight.sh" ]] || { echo "error: preflight missing from bundle" >&2; exit 1; }

# Prefer the formal timer recorded before bootstrap. Fall back to the recovery
# transaction timer for compatibility with older bundles/rehearsals.
if [[ -s "$REHEARSAL_STATE_DIR/timer" ]]; then
  TIMER="$REHEARSAL_STATE_DIR/timer"
  timer_scope="full-rehearsal"
elif [[ -s "$RECOVERY_STATE_DIR/timer" ]]; then
  TIMER="$RECOVERY_STATE_DIR/timer"
  timer_scope="recovery-transaction-only"
else
  echo "error: no rehearsal/recovery timer found" >&2
  exit 1
fi

start="$(awk -F= '$1=="started_epoch"{print $2}' "$TIMER")"
started_at="$(awk -F= '$1=="started_at"{print $2}' "$TIMER")"
BASELINE="$(awk -F= '$1=="baseline_rto_seconds"{print $2}' "$TIMER")"
[[ -n "$BASELINE" ]] || BASELINE="$DEFAULT_BASELINE"
[[ "$start" =~ ^[0-9]+$ ]] || { echo "error: invalid timer" >&2; exit 1; }
[[ "$BASELINE" =~ ^[0-9]+$ ]] || { echo "error: invalid baseline" >&2; exit 1; }
end="$(date +%s)"; ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; rto=$((end-start)); delta=$((rto-BASELINE))
format_duration(){ local n="$1" sign=""; if ((n<0)); then sign="-"; n=$((-n)); fi; printf '%s%02dh%02dm%02ds' "$sign" "$((n/3600))" "$(((n%3600)/60))" "$((n%60))"; }
find_one(){ local dir="$1" pattern="$2"; local a; mapfile -t a < <(find "$dir" -maxdepth 1 -type f -name "$pattern" | sort); [[ ${#a[@]} -eq 1 ]] || return 1; printf '%s' "${a[0]}"; }
cp_archive="$(find_one "$BUNDLE/backups/control-plane" 'k3s-*.tar.gz' || true)"; pv_archive="$(find_one "$BUNDLE/backups/persistent-volumes" 'k3s-persistent-volumes-*.tar.gz' || true)"
cp_meta="unknown"; if [[ -n "$cp_archive" ]]; then cp_meta="$(tar -xOf "$cp_archive" metadata.txt 2>/dev/null | awk -F= '$1=="created_at_utc"{print $2; exit}' || true)"; [[ -n "$cp_meta" ]] || cp_meta="unknown"; fi
pv_meta="unknown"; if [[ -n "$pv_archive" && -s "${pv_archive}.metadata" ]]; then pv_meta="$(awk -F= '$1 ~ /^(snapshot_time|snapshot_at|created_at_utc|created_at)$/ {print $2; exit}' "${pv_archive}.metadata" || true)"; [[ -n "$pv_meta" ]] || pv_meta="unknown"; fi
preflight_out="$(mktemp)"; trap 'rm -f "$preflight_out"' EXIT
if bash "$S/dr-preflight.sh" full >"$preflight_out" 2>&1; then result=PASS; else result=FAIL; fi
install -d -m 0700 "$(dirname "$OUT")"
{
 echo "guiosoft-k3s-lab DR rehearsal report"; echo "result=$result"; echo "hostname=$(hostname -s)"; echo "timer_scope=$timer_scope"; echo "started_at=$started_at"; echo "ended_at=$ended_at"; echo "rto_seconds=$rto"; echo "rto=$(format_duration "$rto")"; echo "baseline_rto_seconds=$BASELINE"; echo "baseline_rto=$(format_duration "$BASELINE")"; echo "delta_seconds=$delta"; echo "delta=$(format_duration "$delta")"; echo "control_plane_backup_created_at=$cp_meta"; echo "persistent_volume_backup_created_at=$pv_meta"; echo "tooling_source_commit=$(awk -F= '$1=="tooling_source_commit"{print $2}' "$BUNDLE/BUNDLE-MANIFEST" 2>/dev/null || true)"; echo; echo "checkpoints:"; find "$RECOVERY_STATE_DIR" -maxdepth 1 -type f -name '*.done' -printf '%f\n' 2>/dev/null | sed 's/\.done$//' | sort | sed 's/^/  PASS /'; echo; echo "full_preflight:"; sed 's/^/  /' "$preflight_out"; echo; echo "safety:"; nft list table inet "${DR_ISOLATION_TABLE:-dr_isolation}" >/dev/null 2>&1 && echo "  PASS WAN isolation active" || echo "  FAIL WAN isolation inactive"; cf="$(k3s kubectl -n cloudflare get deploy cloudflared -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"; [[ -z "$cf" || "$cf" == 0 ]] && echo "  PASS cloudflared inactive" || echo "  FAIL cloudflared replicas=$cf";
} >"$OUT"
cat "$OUT"
[[ "$result" == PASS ]] || exit 1
