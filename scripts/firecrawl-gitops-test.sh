#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${FIRECRAWL_NAMESPACE:-firecrawl}"
DEPLOYMENT="${FIRECRAWL_GITOPS_TEST_DEPLOYMENT:-firecrawl-api}"
KUSTOMIZATION="${FIRECRAWL_FLUX_KUSTOMIZATION:-firecrawl}"
EXPECTED_HOST="${FIRECRAWL_HOST:-firecrawl.guiosoft.info}"
EXPECTED_REPLICAS="${FIRECRAWL_EXPECTED_REPLICAS:-1}"
DRIFT_REPLICAS="${FIRECRAWL_DRIFT_REPLICAS:-2}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

need kubectl
need flux
need curl

if [[ "$DRIFT_REPLICAS" == "$EXPECTED_REPLICAS" ]]; then
  echo "error: FIRECRAWL_DRIFT_REPLICAS must differ from FIRECRAWL_EXPECTED_REPLICAS" >&2
  exit 1
fi

current="$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
if [[ "$current" != "$EXPECTED_REPLICAS" ]]; then
  echo "error: deployment/$DEPLOYMENT currently declares $current replica(s); expected $EXPECTED_REPLICAS before test" >&2
  echo "Refusing to mutate an unexpected runtime state." >&2
  exit 1
fi

if ! flux get kustomization "$KUSTOMIZATION" | grep -Eq 'True'; then
  echo "error: Flux Kustomization '$KUSTOMIZATION' is not Ready" >&2
  flux get kustomization "$KUSTOMIZATION" || true
  exit 1
fi

echo "Firecrawl GitOps drift/self-healing test"
echo "- namespace: $NAMESPACE"
echo "- deployment: $DEPLOYMENT"
echo "- Git desired replicas: $EXPECTED_REPLICAS"
echo "- temporary drift replicas: $DRIFT_REPLICAS"
echo

echo "Introducing harmless positive-capacity drift..."
kubectl -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$DRIFT_REPLICAS"
kubectl -n "$NAMESPACE" rollout status deployment "$DEPLOYMENT" --timeout=240s

actual="$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
if [[ "$actual" != "$DRIFT_REPLICAS" ]]; then
  echo "error: failed to establish drift; replicas=$actual" >&2
  exit 1
fi

echo "Drift established: replicas=$actual"
echo
echo "Reconciling Flux Kustomization '$KUSTOMIZATION'..."
flux reconcile kustomization "$KUSTOMIZATION" --with-source
kubectl -n "$NAMESPACE" rollout status deployment "$DEPLOYMENT" --timeout=240s

actual="$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
available="$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.status.availableReplicas}')"
available="${available:-0}"

if [[ "$actual" != "$EXPECTED_REPLICAS" ]]; then
  echo "error: Flux did not restore replicas; expected=$EXPECTED_REPLICAS actual=$actual" >&2
  exit 1
fi

if [[ "$available" != "$EXPECTED_REPLICAS" ]]; then
  echo "error: deployment not fully available after reconciliation; expected=$EXPECTED_REPLICAS available=$available" >&2
  exit 1
fi

echo "Self-healing confirmed: replicas=$actual available=$available"
echo

echo "Validating LAN endpoint: http://$EXPECTED_HOST/"
code="$(curl --silent --show-error --connect-timeout 5 --max-time 15 -o /dev/null -w '%{http_code}' "http://$EXPECTED_HOST/")"
if [[ "$code" != "200" ]]; then
  echo "error: LAN Firecrawl endpoint returned HTTP $code" >&2
  exit 1
fi

echo "LAN endpoint: HTTP 200"
echo
echo "Firecrawl GitOps drift/self-healing validation: OK"
