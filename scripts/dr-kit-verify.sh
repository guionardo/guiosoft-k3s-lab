#!/usr/bin/env bash
set -euo pipefail
KIT="${1:-}"
[[ -n "$KIT" && -d "$KIT" ]] || { echo "usage: $0 /path/to/dr-kit" >&2; exit 2; }
[[ -s "$KIT/MANIFEST" && -s "$KIT/SHA256SUMS" ]] || { echo "error: invalid DR kit structure" >&2; exit 1; }
grep -qx 'format=guiosoft-k3s-dr-kit-v1' "$KIT/MANIFEST" || { echo "error: unsupported DR kit format" >&2; exit 1; }
(
  cd "$KIT"
  sha256sum -c SHA256SUMS
)
required=(dr-target-init.sh dr-network-isolation.sh dr-preflight.sh dr-restore-k3s.sh k3s-backup-verify.sh dr-neutralize.sh dr-pv-import.sh dr-pv-remap.sh dr-oci-preload.sh)
for name in "${required[@]}"; do
  [[ -x "$KIT/scripts/$name" ]] || { echo "error: missing/non-executable recovery script: scripts/$name" >&2; exit 1; }
done
echo "DR tooling kit verified."
grep -E '^(created_at|source_commit|source_tree)=' "$KIT/MANIFEST"
