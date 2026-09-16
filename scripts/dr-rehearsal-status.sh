#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"
STATE_DIR="${DR_REHEARSAL_STATE_DIR:-/var/lib/guiosoft-k3s-lab/dr-rehearsal}"
STATE_FILE="$STATE_DIR/state.env"
REPORT_FILE="$STATE_DIR/report.txt"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -s "$MARKER_FILE" ]] || { echo "error: DR marker missing" >&2; exit 1; }
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || { echo "error: invalid DR marker" >&2; exit 1; }
install -d -m 0700 "$STATE_DIR"

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "$ACTION" in
  start)
    cat >"$STATE_FILE" <<EOF
started_epoch=$(now_epoch)
started_at=$(now_iso)
hostname=$(hostname -s)
EOF
    chmod 0600 "$STATE_FILE"
    echo "DR rehearsal timer started: $(now_iso)"
    ;;
  finish)
    [[ -s "$STATE_FILE" ]] || { echo "error: rehearsal was not started" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    finished_epoch="$(now_epoch)"
    finished_at="$(now_iso)"
    rto_seconds=$((finished_epoch - started_epoch))
    backup_time="${DR_RECOVERED_BACKUP_TIME:-unknown}"
    rpo_seconds="unknown"
    if [[ "$backup_time" != "unknown" ]]; then
      backup_epoch="$(date -d "$backup_time" +%s)"
      rpo_seconds=$((started_epoch - backup_epoch))
    fi
    cat >"$REPORT_FILE" <<EOF
DR rehearsal report
host=$hostname
started_at=$started_at
finished_at=$finished_at
rto_seconds=$rto_seconds
recovered_backup_time=$backup_time
rpo_seconds=$rpo_seconds
wan_isolation=$(nft list table inet dr_isolation >/dev/null 2>&1 && echo active || echo inactive)
k3s_ready=$(k3s kubectl get --raw=/readyz >/dev/null 2>&1 && echo yes || echo no)
EOF
    chmod 0600 "$REPORT_FILE"
    cat "$REPORT_FILE"
    ;;
  status)
    [[ -s "$STATE_FILE" ]] && { echo "--- timer ---"; cat "$STATE_FILE"; } || echo "timer: not started"
    [[ -s "$REPORT_FILE" ]] && { echo "--- latest report ---"; cat "$REPORT_FILE"; } || true
    echo "--- preflight ---"
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$SCRIPT_DIR/dr-preflight.sh" || true
    ;;
  *) echo "usage: $0 {start|status|finish}" >&2; exit 2 ;;
esac
