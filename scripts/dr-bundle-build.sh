#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-}"
TOOLING_KIT="${DR_TOOLING_KIT:-}"
OCI_KIT="${DR_OCI_KIT:-}"
CONTROL_PLANE_ARCHIVE="${DR_CONTROL_PLANE_ARCHIVE:-}"
PV_ARCHIVE="${DR_PV_ARCHIVE:-}"
RECOVERY_SET_METADATA="${DR_RECOVERY_SET_METADATA:-}"
ENCRYPTED_DIR="${DR_ENCRYPTED_MATERIAL_DIR:-}"

[[ -n "$OUT" ]] || { echo "usage: DR_TOOLING_KIT=... DR_OCI_KIT=... DR_CONTROL_PLANE_ARCHIVE=... DR_PV_ARCHIVE=... DR_RECOVERY_SET_METADATA=... $0 /path/to/bundle" >&2; exit 2; }
[[ ! -e "$OUT" ]] || { echo "error: output already exists: $OUT" >&2; exit 1; }
for p in "$TOOLING_KIT" "$OCI_KIT"; do [[ -n "$p" && -d "$p" ]] || { echo "error: required kit directory missing: $p" >&2; exit 1; }; done
for p in "$CONTROL_PLANE_ARCHIVE" "$PV_ARCHIVE"; do [[ -n "$p" && -s "$p" && -s "${p}.sha256" ]] || { echo "error: archive/checksum missing: $p" >&2; exit 1; }; done
[[ -n "$RECOVERY_SET_METADATA" && -s "$RECOVERY_SET_METADATA" ]] || { echo "error: portable recovery-set metadata required" >&2; exit 1; }
grep -qx 'format=guiosoft-k3s-portable-recovery-set-v1' "$RECOVERY_SET_METADATA" || { echo "error: unsupported portable recovery-set metadata" >&2; exit 1; }
RECOVERY_SET_ID="$(awk -F= '$1=="backup_set_id"{print $2}' "$RECOVERY_SET_METADATA")"
RECOVERY_SET_CP="$(awk -F= '$1=="control_plane_archive"{print $2}' "$RECOVERY_SET_METADATA")"
[[ -n "$RECOVERY_SET_ID" ]] || { echo "error: recovery-set backup_set_id missing" >&2; exit 1; }
[[ "$RECOVERY_SET_CP" == "$(basename "$CONTROL_PLANE_ARCHIVE")" ]] || { echo "error: control-plane archive does not match recovery set $RECOVERY_SET_ID" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/dr-kit-verify.sh" "$TOOLING_KIT" >/dev/null
( cd "$OCI_KIT" && [[ -s SHA256SUMS ]] && sha256sum -c SHA256SUMS >/dev/null ) || { echo "error: OCI kit integrity check failed" >&2; exit 1; }

install -d -m 0700 "$OUT/tooling" "$OUT/oci" "$OUT/backups/control-plane" "$OUT/backups/persistent-volumes" "$OUT/recovery-set" "$OUT/encrypted"
cp -a "$TOOLING_KIT/." "$OUT/tooling/"
cp -a "$OCI_KIT/." "$OUT/oci/"
cp -a "$CONTROL_PLANE_ARCHIVE" "${CONTROL_PLANE_ARCHIVE}.sha256" "$OUT/backups/control-plane/"
cp -a "$PV_ARCHIVE" "${PV_ARCHIVE}.sha256" "$OUT/backups/persistent-volumes/"
[[ ! -s "${PV_ARCHIVE}.metadata" ]] || cp -a "${PV_ARCHIVE}.metadata" "$OUT/backups/persistent-volumes/"
cp -a "$RECOVERY_SET_METADATA" "$OUT/recovery-set/metadata"

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
format=guiosoft-k3s-dr-bundle-v2
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
builder_host=$(hostname -s)
tooling_source_commit=$(awk -F= '$1=="source_commit"{print $2}' "$TOOLING_KIT/MANIFEST")
backup_set_id=$RECOVERY_SET_ID
control_plane_archive=$(basename "$CONTROL_PLANE_ARCHIVE")
pv_archive=$(basename "$PV_ARCHIVE")
control_plane_restic_snapshot_id=$(awk -F= '$1=="control_plane_restic_snapshot_id"{print $2}' "$RECOVERY_SET_METADATA")
pv_restic_snapshot_id=$(awk -F= '$1=="pv_restic_snapshot_id"{print $2}' "$RECOVERY_SET_METADATA")
consistency_window_seconds=$(awk -F= '$1=="consistency_window_seconds"{print $2}' "$RECOVERY_SET_METADATA")
EOF

cat >"$OUT/RECOVERY.txt" <<'EOF'
guiosoft-k3s-lab offline full-DR bundle

This bundle is bound to one verified bounded-consistency recovery set. Treat
BUNDLE-MANIFEST backup_set_id as the recovery unit; do not substitute an
independent control-plane or persistent-volume archive.

SAFETY BOUNDARY
- Never run this recovery on production hostname/IP.
- Keep WAN isolation active from the isolated stage through final validation.
- Never start cloudflared or unsuspend Flux during a rehearsal.
- The control-plane archive contains the K3s server token; protect this bundle.

PREPARE CLEAN TARGET
1. Verify the bundle:
     sudo tooling/scripts/dr-bundle-verify.sh <bundle>
2. Bootstrap clean K3s from tooling/ansible while WAN access is still available.
3. Run clean preflight before isolation:
     sudo tooling/scripts/dr-preflight.sh clean
4. Set `disable-agent: true` in /etc/rancher/k3s/config.yaml and restart K3s.
   Confirm the API is ready. The recovery orchestrator will refuse to continue
   unless this explicit agentless boundary is present.

DESTRUCTIVE ISOLATED RECOVERY
5. Run the checkpointed recovery transaction:
     sudo env DR_RECOVERY_CONFIRM=recover-isolated-k3s \
       tooling/scripts/dr-recover.sh <bundle>
   This initializes the DR marker, enables WAN isolation, restores the control
   plane, neutralizes Flux/public/application workloads, imports/remaps PVs and
   installs the OCI preload. Completed stages are recorded under
   /var/lib/guiosoft-k3s-dr/recovery and are resumable.

CONTROLLED ACTIVATION
6. Activate only the four approved persistent observability workloads:
     sudo env DR_ACTIVATE_CONFIRM=activate-isolated-observability \
       tooling/scripts/dr-activate-observability.sh
   This removes disable-agent, restarts K3s and starts only Tempo, Loki,
   Prometheus and Grafana after rechecking PV/Flux/cloudflared safety.

FORMAL RESULT
7. Close the rehearsal and compare RTO with the 4029-second baseline:
     sudo tooling/scripts/dr-rehearsal-report.sh <bundle>
   A PASS requires full preflight success while WAN isolation remains active
   and cloudflared remains inactive.

DO NOT disable WAN isolation merely to update Git or fetch missing files. A
valid bundle is self-contained for the recovery path. Encrypted material still
requires its independently held decryption identity/passphrase.
EOF

(
  cd "$OUT"
  find . -type f ! -name BUNDLE-SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >BUNDLE-SHA256SUMS
  sha256sum -c BUNDLE-SHA256SUMS >/dev/null
)
chmod 0600 "$OUT/BUNDLE-MANIFEST" "$OUT/BUNDLE-SHA256SUMS" "$OUT/RECOVERY.txt" "$OUT/recovery-set/metadata"
echo "Full offline DR bundle built and verified: $OUT"
echo "backup_set_id=$RECOVERY_SET_ID"
