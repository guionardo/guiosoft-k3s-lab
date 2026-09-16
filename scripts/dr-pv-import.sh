#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-}"
TARGET="${K3S_DR_PV_TARGET:-/var/lib/rancher/k3s/storage}"
MARKER_FILE="${DR_MARKER_FILE:-/etc/guiosoft-k3s-lab/dr-rehearsal-target}"
ISOLATION_TABLE="${DR_ISOLATION_TABLE:-dr_isolation}"
CONFIRM_EXPECTED="import-isolated-pvs"
METADATA="${ARCHIVE}.metadata"

[[ ${EUID} -eq 0 ]] || { echo "error: run as root" >&2; exit 1; }
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "usage: $0 /path/to/k3s-persistent-volumes.tar.gz" >&2; exit 2; }
[[ -s "${ARCHIVE}.sha256" ]] || { echo "error: checksum file missing: ${ARCHIVE}.sha256" >&2; exit 1; }
[[ -s "$MARKER_FILE" ]] || { echo "error: DR marker missing: $MARKER_FILE" >&2; exit 1; }
grep -qx 'mode=isolated-dr-rehearsal' "$MARKER_FILE" || { echo "error: invalid DR marker" >&2; exit 1; }
nft list table inet "$ISOLATION_TABLE" >/dev/null 2>&1 || { echo "error: DR WAN isolation is not active" >&2; exit 1; }
[[ "${DR_PV_IMPORT_CONFIRM:-}" == "$CONFIRM_EXPECTED" ]] || { echo "error: explicit confirmation required: DR_PV_IMPORT_CONFIRM=$CONFIRM_EXPECTED" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

expected="$(awk 'NR==1 {print $1}' "${ARCHIVE}.sha256")"
actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$expected" == "$actual" ]] || { echo "error: SHA-256 mismatch or invalid checksum" >&2; exit 1; }
tar -tzf "$ARCHIVE" >/dev/null

# Validate every member before extraction. Reject absolute paths, traversal,
# device nodes and symlinks/hardlinks. A DR archive should contain directories
# and regular local-path volume files only.
python3 - "$ARCHIVE" <<'PY'
import sys,tarfile,pathlib
archive=sys.argv[1]
with tarfile.open(archive, 'r:gz') as tf:
    members=tf.getmembers()
    if not members:
        raise SystemExit('error: PV archive is empty')
    for m in members:
        name=m.name
        p=pathlib.PurePosixPath(name)
        parts=[x for x in p.parts if x not in ('', '.')]
        if p.is_absolute() or '..' in parts:
            raise SystemExit(f'error: unsafe archive path: {name}')
        if m.issym() or m.islnk() or m.isdev():
            raise SystemExit(f'error: unsupported archive member type: {name}')
        if not (m.isdir() or m.isfile()):
            raise SystemExit(f'error: unsupported archive member: {name}')
PY

# New exports carry metadata declaring the portable v1 layout. For the known
# legacy rehearsal artifact (which used local-path/... and required stripping
# one component), compatibility remains explicit and structurally validated.
strip_args=()
if [[ -s "$METADATA" ]]; then
  grep -qx 'format=k3s-pv-archive-v1' "$METADATA" || { echo "error: unsupported PV archive metadata format" >&2; exit 1; }
else
  first_components="$(tar -tzf "$ARCHIVE" | sed -e 's#^\./##' -e '/^$/d' | cut -d/ -f1 | sort -u)"
  if [[ "$first_components" == "local-path" ]]; then
    echo "warning: importing legacy local-path archive format; create future exports with k3s-pv-archive-v1" >&2
    strip_args=(--strip-components=1)
  else
    echo "error: archive has no v1 metadata and does not match the supported legacy local-path layout" >&2
    exit 1
  fi
fi

install -d -m 0755 "$TARGET"
if find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  echo "error: target is not empty: $TARGET" >&2
  echo "clear/move the previous rehearsal data explicitly before importing" >&2
  exit 1
fi

tar --numeric-owner -xzf "$ARCHIVE" -C "$TARGET" "${strip_args[@]}"

[[ -n "$(find "$TARGET" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]] || {
  echo "error: extraction completed but no PV directories exist under $TARGET" >&2
  exit 1
}

echo "Persistent-volume archive imported with numeric ownership preserved."
echo "target=$TARGET sha256=$actual"
du -sh "$TARGET"
