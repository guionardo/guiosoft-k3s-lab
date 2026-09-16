#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-}"
PLATFORM="${DR_OCI_PLATFORM:-linux/amd64}"
[[ -n "$OUT" ]] || { echo "usage: $0 /path/to/output-kit" >&2; exit 2; }
command -v docker >/dev/null || { echo "error: docker is required as an independent registry-backed image source" >&2; exit 1; }
install -d -m 0755 "$OUT"

# Keep this explicit and reviewable. Add images here as the DR-critical workload
# set changes. The pause image is mandatory for offline K3s Pod sandboxes.
images=(
  'docker.io/rancher/mirrored-pause:3.10.2'
  'docker.io/library/busybox:1.38.0'
  'quay.io/kiwigrid/k8s-sidecar:2.11.0'
  'docker.io/grafana/grafana:13.2.1-distroless'
  'docker.io/grafana/tempo:2.10.7'
  'docker.io/grafana/loki:3.7.3'
  'docker.io/kiwigrid/k8s-sidecar:2.8.1'
  'quay.io/prometheus/prometheus:v3.14.0-distroless'
  'quay.io/prometheus-operator/prometheus-config-reloader:v0.93.1'
)

manifest="$OUT/images.txt"
: >"$manifest"
for image in "${images[@]}"; do
  safe="$(printf '%s' "$image" | sed 's#[/:]#_#g')"
  archive="$OUT/${safe}.tar"
  echo "=== $image ==="
  docker pull --platform "$PLATFORM" "$image"
  docker image inspect "$image" --format '{{.Os}}/{{.Architecture}} {{.Id}}'
  docker save -o "$archive" "$image"
  tar -tf "$archive" >/dev/null
  printf '%s\t%s\n' "$image" "$(basename "$archive")" >>"$manifest"
done

(
  cd "$OUT"
  find . -maxdepth 1 -type f -name '*.tar' -printf '%f\n' | sort | xargs -r sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS
)

cat >"$OUT/metadata.txt" <<EOF
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
platform=$PLATFORM
builder_host=$(hostname -s)
image_count=${#images[@]}
EOF

echo "OCI DR kit built and validated: $OUT"
echo "Images: ${#images[@]}"
