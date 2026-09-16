#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${1:-}"
IMAGE_DIR="${K3S_IMAGE_DIR:-/var/lib/rancher/k3s/agent/images}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
CHECKSUM_FILE="${DR_OCI_CHECKSUM_FILE:-SHA256SUMS}"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "$SOURCE_DIR" && -d "$SOURCE_DIR" ]] || { echo "usage: $0 /path/to/oci-kit" >&2; exit 2; }
[[ -s "$MARKER_FILE" ]] || { echo "error: DR target marker missing: $MARKER_FILE" >&2; exit 1; }
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || { echo "error: invalid DR target marker" >&2; exit 1; }
[[ -f "$SOURCE_DIR/$CHECKSUM_FILE" ]] || { echo "error: missing $SOURCE_DIR/$CHECKSUM_FILE" >&2; exit 1; }

(
  cd "$SOURCE_DIR"
  sha256sum -c "$CHECKSUM_FILE"
)

install -d -m 0755 "$IMAGE_DIR"
count=0
while IFS= read -r archive; do
  tar -tf "$archive" >/dev/null
  install -m 0644 "$archive" "$IMAGE_DIR/$(basename "$archive")"
  count=$((count + 1))
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -name '*.tar' -print | sort)

[[ $count -gt 0 ]] || { echo "error: no .tar image archives found in $SOURCE_DIR" >&2; exit 1; }
echo "Installed $count validated OCI archive(s) into K3s native image preload: $IMAGE_DIR"
echo "K3s will import/pin these images through its air-gap image mechanism."
