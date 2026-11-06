#!/usr/bin/env bash
# Retention probe for the LAN OCI registry (Zot).
#
# Pushes N distinct images to a fresh repository, restarts the zot Pod so the
# garbage collector runs, and prints the tag list before and after. The
# expected outcome is: N tags -> 10 tags, keeping the 10 most recently pushed.
#
# Run this on the K3s node (where docker is native), or via:
#   ssh guionardo@192.168.88.9 'bash -s' < scripts/registry-retention-probe.sh
#
# Requires REGISTRY_PASSWORD (pusher) in the environment.
set -euo pipefail

N="${COUNT:-12}"
REPO="retention-probe-$(date +%Y%m%d%H%M%S)"
PW="${REGISTRY_PASSWORD:?set REGISTRY_PASSWORD to the pusher password}"

CTX=/tmp/registry-retention-ctx
rm -rf "$CTX"; mkdir -p "$CTX"
cat > "$CTX/Dockerfile" <<'EOF'
FROM alpine:3.22
COPY marker.txt /marker.txt
EOF

# Port-forward the zot Service so we can push over plain HTTP (localhost is
# insecure by default in Docker, which avoids the self-signed cert problem).
kubectl port-forward -n registry svc/zot 5000:5000 >/tmp/registry-pf.log 2>&1 &
PF_PID=$!
cleanup() { kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 30); do
  curl -s http://127.0.0.1:5000/v2/ >/dev/null 2>&1 && break
  sleep 1
done
curl -s http://127.0.0.1:5000/v2/ >/dev/null 2>&1 || { echo "port-forward failed"; cat /tmp/registry-pf.log; exit 1; }

echo "== login =="
printf '%s' "$PW" | docker login localhost:5000 -u pusher --password-stdin >/dev/null

echo "== pushing $N distinct images to $REPO =="
for i in $(seq 1 "$N"); do
  printf 'marker-%d-%s\n' "$i" "$(date +%s%N)" > "$CTX/marker.txt"
  docker build -q -t "localhost:5000/$REPO:v$i" "$CTX" >/dev/null
  docker push "localhost:5000/$REPO:v$i" >/dev/null
  echo "  pushed v$i"
done

echo "== tags before GC =="
curl -s -u "pusher:$PW" "http://127.0.0.1:5000/v2/$REPO/tags/list"

echo "== restarting zot (GC trigger) =="
kubectl rollout restart deployment/zot -n registry
kubectl rollout status deployment/zot -n registry --timeout=180s

echo "== tags after GC =="
curl -s -u "pusher:$PW" "http://127.0.0.1:5000/v2/$REPO/tags/list"
echo