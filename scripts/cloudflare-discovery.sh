#!/usr/bin/env bash
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?Export CLOUDFLARE_API_TOKEN before running this script}"

ZONE_NAME="${CLOUDFLARE_ZONE_NAME:-guiosoft.info}"
API_BASE="https://api.cloudflare.com/client/v4"
AUTH_HEADER="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

api_get() {
  curl --fail --silent --show-error \
    -H "${AUTH_HEADER}" \
    -H 'Content-Type: application/json' \
    "$1"
}

zone_json="$(api_get "${API_BASE}/zones?name=${ZONE_NAME}")"
zone_count="$(jq '.result | length' <<<"${zone_json}")"

if [[ "${zone_count}" -ne 1 ]]; then
  echo "Expected exactly one zone named ${ZONE_NAME}; found ${zone_count}." >&2
  exit 1
fi

zone_id="$(jq -r '.result[0].id' <<<"${zone_json}")"
account_id="$(jq -r '.result[0].account.id' <<<"${zone_json}")"

printf 'Cloudflare zone\n'
printf '  name:       %s\n' "${ZONE_NAME}"
printf '  zone_id:    %s\n' "${zone_id}"
printf '  account_id: %s\n' "${account_id}"
printf '\n'

wildcard_json="$(api_get "${API_BASE}/zones/${zone_id}/dns_records?type=CNAME&name=%2A.${ZONE_NAME}")"

printf 'Wildcard DNS candidates\n'
jq -r '.result[] | "  id: \(.id)\n  name: \(.name)\n  content: \(.content)\n  proxied: \(.proxied)\n"' <<<"${wildcard_json}"
printf '\n'

tunnels_json="$(api_get "${API_BASE}/accounts/${account_id}/cfd_tunnel?is_deleted=false")"

printf 'Cloudflare Tunnel candidates\n'
jq -r '.result[] | "  id: \(.id)\n  name: \(.name)\n  status: \(.status)\n  remote_config: \(.remote_config // false)\n"' <<<"${tunnels_json}"

printf '\nNo API token or tunnel token was printed.\n'
