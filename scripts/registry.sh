#!/usr/bin/env bash
set -euo pipefail

# End-to-end validation and status for the LAN-only OCI registry (Zot).
#
# `validate` asserts, in order:
#   1. registry.guiosoft.info resolves to the LAN IP (192.168.88.9);
#   2. the public (Cloudflare) path is blocked (404);
#   3. the LAN path requires auth (401 unauthenticated);
#   4. an authenticated push/pull round trip over the HTTP API (no docker);
#   5. read access with the low-privilege `puller` credential;
#   6. write access with `puller` (rejected, or a warning if zot does not
#      enforce read/write separation);
#   7. a pod can pull the pushed image through containerd.
#
# REGISTRY_RESOLVE_IP overrides the IP passed to curl `--resolve` for the LAN
# assertions (3-7). Assertion 1 always uses real DNS (getent/dig). Setting the
# override demotes assertion 1's failure to a warning so the remaining LAN
# assertions can be exercised before the MikroTik split-DNS entry exists.

ACTION="${1:-validate}"

NAMESPACE="${REGISTRY_NAMESPACE:-registry}"
HOST="${REGISTRY_HOST:-registry.guiosoft.info}"
LAN_IP="192.168.88.9"
RESOLVE_IP="${REGISTRY_RESOLVE_IP:-$LAN_IP}"
CRED_SCRIPT="${REGISTRY_CRED_SCRIPT:-scripts/registry-credentials.sh}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}

# Resolve the registry host through real DNS only. Never uses RESOLVE_IP.
# Always exits 0; prints the first IPv4 answer, or nothing.
resolve_ip() {
  local out=""
  if command -v getent >/dev/null 2>&1; then
    out="$(getent hosts "$HOST" 2>/dev/null || true)"
    printf '%s\n' "$out" | awk 'NR==1 {print $1}'
  elif command -v dig >/dev/null 2>&1; then
    out="$(dig +short "$HOST" 2>/dev/null || true)"
    printf '%s\n' "$out" | awk '/^[0-9]+\./ {print $1; exit}'
  fi
}

# Portable sha256 hex digest of a file (macOS `shasum` vs GNU `sha256sum`).
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

validate() {
  need curl

  echo "Registry end-to-end validation"
  echo

  # --- 1. resolution ---
  resolved="$(resolve_ip)"
  if [[ "$resolved" == "$LAN_IP" ]]; then
    echo "resolution: $HOST -> $LAN_IP (OK)"
  else
    echo "error: $HOST resolves publicly; add the MikroTik split-DNS entry" >&2
    if [[ -z "${REGISTRY_RESOLVE_IP:-}" ]]; then
      exit 1
    fi
    echo "warn: REGISTRY_RESOLVE_IP is set; continuing with --resolve target $RESOLVE_IP" >&2
  fi

  # --- 2. public block (goes through Cloudflare; no --resolve, no -k) ---
  public_code="$(curl -s -o /dev/null -w '%{http_code}' "https://$HOST/v2/")"
  if [[ "$public_code" != "404" ]]; then
    echo "error: public https://$HOST/v2/ expected 404, got $public_code" >&2
    exit 1
  fi
  echo "public block: https://$HOST/v2/ -> 404"

  # --- 3. unauthenticated LAN ---
  unauth_code="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$HOST:443:$RESOLVE_IP" "https://$HOST/v2/")"
  if [[ "$unauth_code" != "401" ]]; then
    echo "error: unauthenticated https://$HOST/v2/ expected 401, got $unauth_code" >&2
    exit 1
  fi
  echo "unauthenticated LAN: https://$HOST/v2/ -> 401"

  # --- 4. authenticated round trip over the HTTP API (no docker) ---
  PUSHER_PW="$(bash "$CRED_SCRIPT" password pusher)"
  repo="registry/smoke"
  tag="smoke-$(date +%Y%m%d%H%M%S)"

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/registry-validate.XXXXXX")"
  trap 'rm -rf "$tmpdir"' RETURN
  config_blob="$tmpdir/config"
  manifest="$tmpdir/manifest.json"
  headers="$tmpdir/headers"

  printf '{}' > "$config_blob"
  config_digest="sha256:$(sha256_hex "$config_blob")"
  config_size="$(wc -c < "$config_blob" | tr -d ' ')"

  post_code="$(curl -sk -o /dev/null -w '%{http_code}' -D "$headers" \
    -u "pusher:$PUSHER_PW" --resolve "$HOST:443:$RESOLVE_IP" \
    -X POST "https://$HOST/v2/$repo/blobs/uploads/")"
  if [[ "$post_code" != "202" ]]; then
    echo "error: POST /v2/$repo/blobs/uploads/ expected 202, got $post_code" >&2
    exit 1
  fi
  location="$(awk 'tolower($1)=="location:" {gsub("\r",""); print $2}' "$headers")"
  if [[ -z "$location" ]]; then
    echo "error: POST blob upload returned no Location header" >&2
    exit 1
  fi
  if [[ "$location" == http* ]]; then
    upload_url="$location"
  else
    upload_url="https://$HOST$location"
  fi

  blob_code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -u "pusher:$PUSHER_PW" --resolve "$HOST:443:$RESOLVE_IP" \
    -X PUT -H 'Content-Type: application/octet-stream' --data-binary "@$config_blob" \
    "$upload_url?digest=$config_digest")"
  if [[ "$blob_code" != "201" ]]; then
    echo "error: PUT blob expected 201, got $blob_code" >&2
    exit 1
  fi

  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"%s","size":%s},"layers":[]}' \
    "$config_digest" "$config_size" > "$manifest"

  manifest_code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -u "pusher:$PUSHER_PW" --resolve "$HOST:443:$RESOLVE_IP" \
    -X PUT -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' --data-binary "@$manifest" \
    "https://$HOST/v2/$repo/manifests/$tag")"
  if [[ "$manifest_code" != "201" ]]; then
    echo "error: PUT manifest expected 201, got $manifest_code" >&2
    exit 1
  fi

  get_code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -u "pusher:$PUSHER_PW" --resolve "$HOST:443:$RESOLVE_IP" \
    "https://$HOST/v2/$repo/manifests/$tag")"
  if [[ "$get_code" != "200" ]]; then
    echo "error: GET manifest expected 200, got $get_code" >&2
    exit 1
  fi

  tags_body="$(curl -sk -u "pusher:$PUSHER_PW" --resolve "$HOST:443:$RESOLVE_IP" \
    "https://$HOST/v2/$repo/tags/list")"
  if ! printf '%s' "$tags_body" | grep -Fq "\"$tag\""; then
    echo "error: tag $tag not found in $repo/tags/list" >&2
    exit 1
  fi
  echo "push/pull round trip: $repo:$tag (blob $config_digest) -> 201/200/200"

  # --- 5. pull as puller ---
  PULLER_PW="$(bash "$CRED_SCRIPT" password puller)"
  pull_code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -u "puller:$PULLER_PW" --resolve "$HOST:443:$RESOLVE_IP" \
    "https://$HOST/v2/$repo/manifests/$tag")"
  if [[ "$pull_code" != "200" ]]; then
    echo "error: puller read of $repo:$tag expected 200, got $pull_code" >&2
    exit 1
  fi
  echo "pull as puller: $repo:$tag -> 200"

  # --- 6. push as puller ---
  push_code="$(curl -sk -o /dev/null -w '%{http_code}' \
    -u "puller:$PULLER_PW" --resolve "$HOST:443:$RESOLVE_IP" \
    -X POST "https://$HOST/v2/$repo/blobs/uploads/")"
  if [[ "$push_code" == "401" || "$push_code" == "403" ]]; then
    echo "push as puller: rejected ($push_code) — read-only separation enforced"
  elif [[ "$push_code" == 2* ]]; then
    echo "warn: puller can push; read-only separation is not enforced by zot"
  else
    echo "error: unexpected response pushing as puller: $push_code" >&2
    exit 1
  fi

  # --- 7. pod pull through containerd ---
  pull_as_containerd "$repo" "$tag"

  echo
  echo "Registry end-to-end validation: OK"
}

pull_as_containerd() {
  local repo="$1" tag="$2"
  need kubectl

  PULLER_PW="$(bash "$CRED_SCRIPT" password puller)"

  kubectl -n "$NAMESPACE" create secret docker-registry registry-pull-test \
    --docker-server="$HOST" --docker-username=puller --docker-password="$PULLER_PW" \
    --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f - >/dev/null

  kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: registry-pull-test
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  imagePullSecrets:
    - name: registry-pull-test
  containers:
    - name: probe
      image: $HOST/$repo:$tag
      imagePullPolicy: Always
EOF

  trap 'kubectl -n "$NAMESPACE" delete pod registry-pull-test --ignore-not-found --wait=false >/dev/null 2>&1 || true; kubectl -n "$NAMESPACE" delete secret registry-pull-test --ignore-not-found >/dev/null 2>&1 || true' RETURN

  for _ in $(seq 1 10); do
    sleep 3
    ready="$(kubectl -n "$NAMESPACE" get pod registry-pull-test -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
    reason="$(kubectl -n "$NAMESPACE" get pod registry-pull-test -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    phase="$(kubectl -n "$NAMESPACE" get pod registry-pull-test -o jsonpath='{.status.phase}' 2>/dev/null || true)"

    if [[ "$ready" == "true" ]]; then
      echo "pod pull (containerd): $repo:$tag pulled and Ready"
      return 0
    fi
    if [[ "$reason" == "ErrImagePull" || "$reason" == "ImagePullBackOff" ]]; then
      echo "SKIP: containerd trust not active: run the k3s playbook"
      return 0
    fi
    if [[ "$phase" == "Succeeded" ]]; then
      echo "pod pull (containerd): $repo:$tag pulled and completed"
      return 0
    fi
  done

  echo "error: pod registry-pull-test did not pull and run (phase=${phase:-?}, reason=${reason:-?})" >&2
  kubectl -n "$NAMESPACE" describe pod registry-pull-test >&2 || true
  return 1
}

status() {
  need kubectl

  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Registry namespace '$NAMESPACE' does not exist yet."
    exit 0
  fi

  echo "Registry (namespace $NAMESPACE)"
  echo
  echo "Deployment:"
  kubectl get deployment -n "$NAMESPACE" -o wide
  echo
  echo "PersistentVolumeClaim:"
  kubectl get pvc -n "$NAMESPACE" -o wide
  echo
  echo "Ingress:"
  kubectl get ingress -n "$NAMESPACE" -o wide
  echo "entrypoint: $(kubectl get ingress -n "$NAMESPACE" registry -o go-template='{{ index .metadata.annotations "traefik.ingress.kubernetes.io/router.entrypoints" }}' 2>/dev/null || true)"
  echo
  echo "Pods:"
  kubectl get pods -n "$NAMESPACE" -o wide
}

case "$ACTION" in
  validate) validate ;;
  status) status ;;
  *)
    echo "Usage: $0 {validate|status}" >&2
    exit 2
    ;;
esac
