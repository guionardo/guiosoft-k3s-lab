#!/usr/bin/env bash
set -euo pipefail

EXPECTED_LOCAL_PATH="${K3S_LOCAL_PATH_ROOT:-/mnt/store1/k3s/local-path}"

command -v kubectl >/dev/null || { echo "error: kubectl not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found" >&2; exit 1; }

printf 'K3s persistence inventory (read-only)\n'
printf 'Generated: %s\n' "$(date --iso-8601=seconds)"
printf 'Expected local-path root: %s\n\n' "$EXPECTED_LOCAL_PATH"

printf '== PersistentVolumeClaims ==\n'
kubectl get pvc -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,STORAGECLASS:.spec.storageClassName,REQUESTED:.spec.resources.requests.storage' || true

printf '\n== PersistentVolumes ==\n'
kubectl get pv -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.namespace/.spec.claimRef.name,STORAGECLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage,RECLAIM:.spec.persistentVolumeReclaimPolicy' || true

printf '\n== Local/host paths backing PVs ==\n'
PV_ROWS="$(kubectl get pv -o json | jq -r '
  .items[]
  | {
      name: .metadata.name,
      namespace: (.spec.claimRef.namespace // "-"),
      claim: (.spec.claimRef.name // "-"),
      storageClass: (.spec.storageClassName // "-"),
      hostPath: (.spec.hostPath.path // ""),
      localPath: (.spec.local.path // "")
    }
  | select((.hostPath | length) > 0 or (.localPath | length) > 0)
  | [
      .namespace,
      .claim,
      .name,
      .storageClass,
      (if (.hostPath | length) > 0 then .hostPath else .localPath end)
    ]
  | @tsv
')"
printf '%s\n' "$PV_ROWS" | awk 'BEGIN { printf "%-24s %-32s %-44s %-20s %s\n", "NAMESPACE", "CLAIM", "PV", "STORAGECLASS", "HOST_PATH" }
         NF { printf "%-24s %-32s %-44s %-20s %s\n", $1, $2, $3, $4, $5 }'

printf '\n== local-path placement check ==\n'
DRIFT=0
while IFS=$'\t' read -r namespace claim pv storage_class path; do
  [[ -n "${pv:-}" ]] || continue
  if [[ "$storage_class" != "local-path" ]]; then
    continue
  fi
  if [[ "$path" == "$EXPECTED_LOCAL_PATH"/* ]]; then
    printf 'OK      %s/%s -> %s\n' "$namespace" "$claim" "$path"
  else
    printf 'WARNING %s/%s -> %s (outside expected root %s)\n' \
      "$namespace" "$claim" "$path" "$EXPECTED_LOCAL_PATH"
    DRIFT=1
  fi
done <<< "$PV_ROWS"

if (( DRIFT )); then
  cat <<EOF

At least one local-path PV was provisioned outside the configured root.
Existing PVs are not relocated when K3s/default-local-storage-path changes.
For disposable test PVCs, delete and recreate the PVC to validate the current provisioning path.
Do not do this to application PVCs without an explicit migration/backup plan.
EOF
fi

printf '\n== Pods mounting PVCs ==\n'
kubectl get pods -A -o json | jq -r '
  .items[] as $pod
  | ($pod.spec.volumes // [])[]?
  | select(.persistentVolumeClaim != null)
  | [
      $pod.metadata.namespace,
      $pod.metadata.name,
      .name,
      .persistentVolumeClaim.claimName
    ]
  | @tsv
' | awk 'BEGIN { printf "%-24s %-48s %-28s %s\n", "NAMESPACE", "POD", "VOLUME", "PVC" }
         { printf "%-24s %-48s %-28s %s\n", $1, $2, $3, $4 }'

cat <<'EOF'

Classification guidance:
- Stateless/reproducible: no data backup required beyond Git/IaC.
- File-oriented PVC: candidate for filesystem-level backup, preferably from a quiesced workload or application-supported snapshot/export.
- Database PVC: do NOT treat a live filesystem copy as the primary backup; use the database-native logical/physical backup mechanism first.
- External service: document provider-specific backup/export and restore procedure.

This command changes nothing in the cluster or host storage.
EOF
