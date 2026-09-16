#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
TARGET="${K3S_DR_PV_TARGET:-/var/lib/rancher/k3s/storage}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
CONFIRM_EXPECTED="import-isolated-pvs"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "usage: $0 /path/to/k3s-persistent-volumes.tar.gz" >&2; exit 2; }
[[ -s "${ARCHIVE}.sha256" ]] || { echo "error: checksum file missing: ${ARCHIVE}.sha256" >&2; exit 1; }
[[ -s "$MARKER_FILE" ]] || { echo "error: DR marker missing: $MARKER_FILE" >&2; exit 1; }
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || { echo "error: invalid DR marker" >&2; exit 1; }
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || { echo "error: DR WAN isolation is not active" >&2; exit 1; }
[[ "${DR_PV_IMPORT_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || { echo "error: explicit confirmation required: DR_PV_IMPORT_CONFIRM=$CONFIRM_EXPECTED" >&2; exit 1; }

expected="$(awk 'NR==1 {print $1}' "${ARCHIVE}.sha256")"
actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
[[ -n "$expected" && "$expected" == "$actual" ]] || { echo "error: SHA-256 mismatch" >&2; exit 1; }
tar -tzf "$ARCHIVE" >/dev/null

# Refuse to overlay non-empty recovered data unless explicitly cleared first.
install -d -m 0755 "$TARGET"
if find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  echo "error: target is not empty: $TARGET" >&2
  echo "clear/move the previous rehearsal data explicitly before importing" >&2
  exit 1
fi

tar --numeric-owner -xzf "$ARCHIVE" -C "$TARGET" --strip-components=1

echo "Persistent-volume archive imported with numeric ownership preserved."
echo "target=$TARGET sha256=$actual"
du -sh "$TARGET"
