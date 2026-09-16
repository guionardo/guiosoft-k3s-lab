#!/usr/bin/env bash
set -euo pipefail

HOST="${FIRECRAWL_HOST:-firecrawl.guiosoft.info}"
TARGET_URL="${FIRECRAWL_SCRAPE_URL:-https://example.com}"
CLIENT_ID="${CF_ACCESS_CLIENT_ID:-}"
CLIENT_SECRET="${CF_ACCESS_CLIENT_SECRET:-}"

need() {
  command -v "$1" >/dev/null || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

need curl
need python3

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "error: CF_ACCESS_CLIENT_ID and CF_ACCESS_CLIENT_SECRET must be set" >&2
  echo "Use one Firecrawl Service Token at a time (Hermes or OpenCode)." >&2
  exit 1
fi

unauth_body="$(mktemp)"
auth_body="$(mktemp)"
trap 'rm -f "$unauth_body" "$auth_body"' EXIT

echo "Firecrawl Cloudflare Access validation"
echo

echo "1. Unauthenticated request must be rejected"
unauth_code="$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
  -o "$unauth_body" -w '%{http_code}' \
  "https://$HOST/")"

if [[ "$unauth_code" != "401" ]]; then
  echo "error: expected HTTP 401 without Service Token, got $unauth_code" >&2
  exit 1
fi

echo "unauthenticated request: HTTP 401 (expected)"

echo
echo "2. Authenticated scrape must succeed"
payload="$(python3 - "$TARGET_URL" <<'PY'
import json, sys
print(json.dumps({"url": sys.argv[1], "formats": ["markdown"]}))
PY
)"

auth_code="$(curl --silent --show-error --connect-timeout 10 --max-time 120 \
  -o "$auth_body" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -H "CF-Access-Client-Id: $CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CLIENT_SECRET" \
  --data "$payload" \
  "https://$HOST/v1/scrape")"

if [[ "$auth_code" != "200" ]]; then
  echo "error: authenticated POST /v1/scrape returned HTTP $auth_code" >&2
  exit 1
fi

python3 - "$auth_body" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text(encoding="utf-8"))
if data.get("success") is not True:
    raise SystemExit("error: Firecrawl response did not contain success=true")
markdown = ((data.get("data") or {}).get("markdown") or "")
if not markdown.strip():
    raise SystemExit("error: Firecrawl response contains no markdown")
print("authenticated POST /v1/scrape: HTTP 200 / success=true")
print(f"returned markdown length: {len(markdown)} characters")
PY

echo
echo "Cloudflare Access validation: OK"
echo "No credential values were printed."
