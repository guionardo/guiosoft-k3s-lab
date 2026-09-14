#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

need helm
need kubectl
need python3

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "error: namespace '$NAMESPACE' does not exist" >&2
  exit 1
fi

runtime="$(mktemp)"
trap 'rm -f "$runtime"' EXIT
helm list -n "$NAMESPACE" -o json >"$runtime"

python3 - "$runtime" <<'PY'
import json
import sys
from pathlib import Path

releases = {r["name"]: r for r in json.loads(Path(sys.argv[1]).read_text())}
expected = {
    "kube-prometheus-stack": "kube-prometheus-stack-89.2.0",
    "tempo": "tempo-2.2.3",
    "otel-collector": "opentelemetry-collector-0.172.1",
    "loki": "loki-18.5.0",
    "alloy": "alloy-1.12.1",
}

errors = []
print("Observability GitOps adoption audit")
print()
for name, chart in expected.items():
    item = releases.get(name)
    if item is None:
        errors.append(f"missing Helm release: {name}")
        print(f"{name}: MISSING (expected {chart})")
        continue

    actual_chart = item.get("chart", "")
    status = item.get("status", "")
    ok = actual_chart == chart and status == "deployed"
    print(f"{name}: chart={actual_chart} status={status} {'OK' if ok else 'MISMATCH'}")
    if actual_chart != chart:
        errors.append(f"{name}: expected chart {chart}, got {actual_chart}")
    if status != "deployed":
        errors.append(f"{name}: expected status deployed, got {status}")

if errors:
    print("\nAudit failed:", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print("\nPinned Helm release versions match the current Git configuration.")
PY

echo
echo "Validating that Helm release values are readable..."
for release in kube-prometheus-stack tempo otel-collector loki alloy; do
  helm get values -n "$NAMESPACE" "$release" -o yaml >/dev/null
  echo "- $release: values readable"
done

echo
echo "Checking workload health..."
kubectl get pods -n "$NAMESPACE" --no-headers | awk '
  BEGIN { bad=0 }
  {
    name=$1; ready=$2; status=$3;
    split(ready, r, "/");
    if (status != "Running" && status != "Completed") {
      print "error: " name " status=" status > "/dev/stderr"; bad=1;
    }
    if (status == "Running" && r[1] != r[2]) {
      print "error: " name " ready=" ready > "/dev/stderr"; bad=1;
    }
  }
  END { exit bad }
'

echo "Pods: healthy"
echo
echo "Observability GitOps adoption audit: OK"
echo "No Kubernetes or Helm resources were changed."
