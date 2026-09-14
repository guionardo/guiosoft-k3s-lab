#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT="$(sudo systemctl cat cloudflared.service)"

TOKEN="$({
  printf '%s\n' "$UNIT"
} | python3 -c '
import re, sys
text = sys.stdin.read()
patterns = [
    r"--token(?:=|\s+)([^\s\"\x27]+)",
    r"TUNNEL_TOKEN=([^\s\"\x27]+)",
]
for pattern in patterns:
    m = re.search(pattern, text)
    if m:
        print(m.group(1))
        raise SystemExit(0)
raise SystemExit(1)
')" || {
  echo "ERROR: could not locate Cloudflare Tunnel token in cloudflared.service" >&2
  exit 1
}

[[ -n "$TOKEN" ]] || {
  echo "ERROR: extracted Cloudflare Tunnel token is empty" >&2
  exit 1
}

CLOUDFLARE_TUNNEL_TOKEN="$TOKEN" "${ROOT_DIR}/scripts/cloudflared-token-secret.sh"
unset TOKEN UNIT CLOUDFLARE_TUNNEL_TOKEN

echo "Cloudflare Tunnel token copied from host systemd configuration into encrypted SOPS Secret."
