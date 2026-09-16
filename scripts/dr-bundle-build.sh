#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-}"
TOOLING_KIT="${DR_TOOLING_KIT:-}"
OCI_KIT="${DR_OCI_KIT:-}"
CONTROL_PLANE_ARCHIVE="${DR_CONTROL_PLANE_ARCHIVE:-}"
PV_ARCHIVE="${DR_PV_ARCHIVE:-}"
ENCRYPTED_DIR="${DR_ENCRYPTED_MATERIAL_DIR:-}"

[[ -n "$OUT" ]] || { echo "usage: DR_TOOLING_KIT=... DR_OCI_KIT=... DR_CONTROL_PLANE_ARCHIVE=... DR_PV_ARCHIVE=... $0 /path/to/bundle" >&2; exit 2; }
[[ ! -e "$OUT" ]] || { echo "error: output already exists: $OUT" >&2; exit 1; }
for p in "$TOOLING_KIT" "$OCI_KIT"; do [[ -n "$p" && -d "$p" ]] || { echo "error: required kit directory missing: $p" >&2; exit 1; }; done
for p in "$CONTROL_PLANE_ARCHIVE" "$PV_ARCHIVE"; do [[ -n "$p" && -s "$p" && -s "${p}.sha256" ]] || { echo "error: archive/checksum missing: $p" >&2; exit 1; }; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/dr-kit-verify.sh" "$TOOLING_KIT" >/dev/null
( cd "$OCI_KIT" && [[ -s SHA256SUMS ]] && sha256sum -c SHA256SUMS >/dev/null ) || { echo "error: OCI kit integrity check failed" >&2; exit 1; }

install -d -m 0700 "$OUT/tooling" "$OUT/oci" "$OUT/backups/control-plane" "$OUT/backups/persistent-volumes" "$OUT/encrypted"
cp -a "$TOOLING_KIT/." "$OUT/tooling/"
cp -a "$OCI_KIT/." "$OUT/oci/"
cp -a "$CONTROL_PLANE_ARCHIVE" "${CONTROL_PLANE_ARCHIVE}.sha256" "$OUT/backups/control-plane/"
cp -a "$PV_ARCHIVE" "${PV_ARCHIVE}.sha256" "$OUT/backups/persistent-volumes/"
[[ ! -s "${PV_ARCHIVE}.metadata" ]] || cp -a "${PV_ARCHIVE}.metadata" "$OUT/backups/persistent-volumes/"

# Only already-encrypted recovery material is accepted. This deliberately does
# not copy a directory blindly: accidental plaintext credentials must fail.
if [[ -n "$ENCRYPTED_DIR" ]]; then
  [[ -d "$ENCRYPTED_DIR" ]] || { echo "error: encrypted material directory missing: $ENCRYPTED_DIR" >&2; exit 1; }
  while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    case "$base" in
      *.sops.yaml|*.sops.yml|*.sops.json|*.age|*.enc) cp -a "$file" "$OUT/encrypted/$base" ;;
      *) echo "error: refusing non-encrypted-looking recovery material: $file" >&2; exit 1 ;;
    esac
  done < <(find "$ENCRYPTED_DIR" -maxdepth 1 -type f -print0)
fi

cat >"$OUT/BUNDLE-MANIFEST" <<EOF
format=guiosoft-k3s-dr-bundle-v1
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
builder_host=$(hostname -s)
tooling_source_commit=$(awk -F= '$1=="source_commit"{print $2}' "$TOOLING_KIT/MANIFEST")
control_plane_archive=$(basename "$CONTROL_PLANE_ARCHIVE")
pv_archive=$(basename "$PV_ARCHIVE")
EOF

cat >"$OUT/RECOVERY.txt" <<'EOF'
guiosoft-k3s-lab offline full-DR bundle

1. Verify this bundle before using any artifact:
     tooling/scripts/dr-bundle-verify.sh <bundle>
2. Bootstrap the clean target using tooling/ansible before WAN isolation.
3. Initialize the DR marker and enable tooling/scripts/dr-network-isolation.sh.
4. Keep WAN isolation active through datastore/PV restore and workload validation.
5. Never expose restored cloudflared/Flux/application workloads before deliberate neutralization.

The bundle must not contain plaintext credentials or a plaintext private age identity.
Encrypted material still requires its independently held decryption identity/passphrase.
EOF

(
  cd "$OUT"
  find . -type f ! -name BUNDLE-SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >BUNDLE-SHA256SUMS
  sha256sum -c BUNDLE-SHA256SUMS >/dev/null
)
chmod 0600 "$OUT/BUNDLE-MANIFEST" "$OUT/BUNDLE-SHA256SUMS" "$OUT/RECOVERY.txt"
echo "Full offline DR bundle built and verified: $OUT"
