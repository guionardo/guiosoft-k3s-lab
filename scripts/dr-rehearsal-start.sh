#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${DR_REHEARSAL_STATE_DIR:-/var/lib/guiosoft-k3s-dr/rehearsal-current}"
TIMER="$STATE_DIR/timer"
BASELINE="${DR_RTO_BASELINE_SECONDS:-4029}"
BUNDLE="${1:-}"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ ! -e "$TIMER" ]] || { echo "error: rehearsal timer already exists: $TIMER" >&2; exit 1; }
[[ "$BASELINE" =~ ^[0-9]+$ ]] || { echo "error: invalid DR_RTO_BASELINE_SECONDS" >&2; exit 1; }

install -d -m 0700 "$STATE_DIR"
{
  echo "started_epoch=$(date +%s)"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname -s)"
  echo "baseline_rto_seconds=$BASELINE"
  if [[ -n "$BUNDLE" && -s "$BUNDLE/BUNDLE-MANIFEST" ]]; then
    awk -F= '$1=="created_at"{print "bundle_created_at=" $2} $1=="tooling_source_commit"{print "tooling_source_commit=" $2}' "$BUNDLE/BUNDLE-MANIFEST"
  fi
} >"$TIMER"
chmod 0600 "$TIMER"

echo "DR rehearsal T0 recorded: $TIMER"
cat "$TIMER"
