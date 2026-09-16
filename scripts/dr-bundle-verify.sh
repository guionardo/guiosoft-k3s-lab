#!/usr/bin/env bash
set -euo pipefail
BUNDLE="${1:-}"
[[ -n "$BUNDLE" && -d "$BUNDLE" ]] || { echo "usage: $0 /path/to/dr-bundle" >&2; exit 2; }
[[ -s "$BUNDLE/BUNDLE-MANIFEST" && -s "$BUNDLE/BUNDLE-SHA256SUMS" ]] || { echo "error: invalid DR bundle structure" >&2; exit 1; }
grep -qx 'format=guiosoft-k3s-dr-bundle-v1' "$BUNDLE/BUNDLE-MANIFEST" || { echo "error: unsupported DR bundle format" >&2; exit 1; }
( cd "$BUNDLE" && sha256sum -c BUNDLE-SHA256SUMS )

for d in tooling oci backups/control-plane backups/persistent-volumes encrypted; do [[ -d "$BUNDLE/$d" ]] || { echo "error: missing bundle directory: $d" >&2; exit 1; }; done
bash "$BUNDLE/tooling/scripts/dr-kit-verify.sh" "$BUNDLE/tooling" >/dev/null
( cd "$BUNDLE/oci" && sha256sum -c SHA256SUMS >/dev/null ) || { echo "error: OCI kit integrity failed" >&2; exit 1; }

verify_archive() {
  local dir="$1" pattern="$2" label="$3" archive checksum expected actual count
  count="$(find "$dir" -maxdepth 1 -type f -name "$pattern" | wc -l)"
  [[ "$count" -eq 1 ]] || { echo "error: expected exactly one $label archive, found $count" >&2; exit 1; }
  archive="$(find "$dir" -maxdepth 1 -type f -name "$pattern" -print -quit)"
  checksum="${archive}.sha256"
  [[ -s "$checksum" ]] || { echo "error: missing $label checksum" >&2; exit 1; }
  expected="$(awk 'NR==1{print $1}' "$checksum")"; actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$expected" == "$actual" ]] || { echo "error: $label SHA-256 mismatch" >&2; exit 1; }
}
verify_archive "$BUNDLE/backups/control-plane" 'k3s-*.tar.gz' 'control-plane'
verify_archive "$BUNDLE/backups/persistent-volumes" 'k3s-persistent-volumes-*.tar.gz' 'persistent-volume'

# Defensive secret hygiene: reject common plaintext credential filenames. This
# is an additional guard, not a substitute for reviewing encrypted material.
if find "$BUNDLE" -type f \( -name 'restic.password' -o -name 'r2.env' -o -name 'age.key' -o -name 'identity.txt' \) -print -quit | grep -q .; then
  echo "error: plaintext-sensitive filename detected in DR bundle" >&2
  exit 1
fi

echo "Full offline DR bundle verified."
grep -E '^(created_at|tooling_source_commit|control_plane_archive|pv_archive)=' "$BUNDLE/BUNDLE-MANIFEST"
