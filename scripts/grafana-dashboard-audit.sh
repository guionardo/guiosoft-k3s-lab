#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
GRAFANA_SERVICE="${GRAFANA_SERVICE:-kube-prometheus-stack-grafana}"
GRAFANA_SECRET="${GRAFANA_SECRET:-kube-prometheus-stack-grafana}"
LOCAL_PORT="${GRAFANA_DASHBOARD_AUDIT_PORT:-13001}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

for cmd in kubectl curl jq; do
  need "$cmd"
done

user="$(kubectl get secret -n "$NAMESPACE" "$GRAFANA_SECRET" -o jsonpath='{.data.admin-user}' | base64 -d)"
password="$(kubectl get secret -n "$NAMESPACE" "$GRAFANA_SECRET" -o jsonpath='{.data.admin-password}' | base64 -d)"
pf_log="$(mktemp)"
pf_pid=""

cleanup() {
  [[ -n "${pf_pid:-}" ]] && kill "$pf_pid" >/dev/null 2>&1 || true
  rm -f "$pf_log"
}
trap cleanup EXIT

kubectl port-forward -n "$NAMESPACE" service/"$GRAFANA_SERVICE" "$LOCAL_PORT":80 >"$pf_log" 2>&1 &
pf_pid=$!

for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${LOCAL_PORT}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

curl --fail --silent "http://127.0.0.1:${LOCAL_PORT}/api/health" >/dev/null || {
  echo "error: Grafana port-forward did not become ready" >&2
  cat "$pf_log" >&2
  exit 1
}

search_json="$(curl --fail --silent --user "$user:$password" "http://127.0.0.1:${LOCAL_PORT}/api/search?type=dash-db&limit=1000")"
count="$(jq 'length' <<<"$search_json")"

echo "Grafana dashboard audit (read-only)"
echo
echo "Dashboards discovered: $count"
echo
printf '%-42s %-28s %-12s %s\n' TITLE UID FOLDER TAGS

jq -r '.[] | [.title, .uid, (.folderTitle // "General"), ((.tags // []) | join(","))] | @tsv' <<<"$search_json" \
  | sort \
  | while IFS=$'\t' read -r title uid folder tags; do
      printf '%-42s %-28s %-12s %s\n' "$title" "$uid" "$folder" "$tags"
    done

echo
echo "Classification hints:"

required_patterns=(
  'Kubernetes / Compute Resources / Cluster'
  'Kubernetes / Compute Resources / Namespace (Pods)'
  'Kubernetes / Compute Resources / Node (Pods)'
  'Node Exporter / Nodes'
  'OTel Go Demo - Application Metrics'
)

for title in "${required_patterns[@]}"; do
  if jq -e --arg title "$title" '.[] | select(.title == $title)' <<<"$search_json" >/dev/null; then
    echo "- present: $title"
  else
    echo "- missing/not matched exactly: $title"
  fi
done

echo
echo "K3s-specific review candidates:"
jq -r '.[] | select((.title | test("etcd|scheduler|controller manager|proxy"; "i"))) | "- \(.title) (uid=\(.uid))"' <<<"$search_json" || true

echo
echo "Platform-specific dashboards:"
for title in 'Node Exporter / AIX' 'Node Exporter / MacOS'; do
  if jq -e --arg title "$title" '.[] | select(.title == $title)' <<<"$search_json" >/dev/null; then
    echo "- present but not applicable to this Linux host: $title"
  fi
done

echo
echo "Dashboard health check:"
errors=0
while IFS=$'\t' read -r uid title; do
  [[ -n "$uid" ]] || continue
  if dashboard_json="$(curl --fail --silent --user "$user:$password" "http://127.0.0.1:${LOCAL_PORT}/api/dashboards/uid/${uid}" 2>/dev/null)"; then
    panels="$(jq '[.dashboard.panels[]?] | length' <<<"$dashboard_json")"
    datasource_errors="$(jq '[.. | objects | .datasource? | select(type == "object") | .uid? | select(. != null and . != "-- Mixed --" and . != "grafana" and . != "prometheus" and . != "loki" and . != "tempo" and . != "alertmanager" and . != "$datasource" and . != "${datasource}")] | unique | length' <<<"$dashboard_json")"
    if (( datasource_errors > 0 )); then
      echo "- WARN: $title ($uid): unexpected datasource UID references"
      jq -r '[.. | objects | .datasource? | select(type == "object") | .uid? | select(. != null and . != "-- Mixed --" and . != "grafana" and . != "prometheus" and . != "loki" and . != "tempo" and . != "alertmanager" and . != "$datasource" and . != "${datasource}")] | unique[] | "    - \(.)"' <<<"$dashboard_json"
      errors=$((errors + 1))
    else
      echo "- OK: $title ($uid): ${panels} top-level panels"
    fi
  else
    echo "- WARN: failed to fetch dashboard $title ($uid)" >&2
    errors=$((errors + 1))
  fi
done < <(jq -r '.[] | [.uid, .title] | @tsv' <<<"$search_json")

echo
if (( errors > 0 )); then
  echo "Dashboard audit completed with $errors warning(s)."
else
  echo "Dashboard audit: OK"
fi

echo "Datasource template variables such as \$datasource and \${datasource} are expected and are not treated as broken UID references."
echo "This command is read-only and does not modify Grafana dashboards or provisioning."
