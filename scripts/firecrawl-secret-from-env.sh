#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-${FIRECRAWL_ENV_FILE:-.env}}"
OUTPUT_FILE="${2:-${FIRECRAWL_SECRET_FILE:-kubernetes/apps/firecrawl/firecrawl-secrets.sops.yaml}}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

for cmd in python3 sops; do
  need "$cmd"
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: Firecrawl dotenv file not found: $ENV_FILE" >&2
  echo "Usage: $0 /path/to/firecrawl/.env [output.sops.yaml]" >&2
  exit 1
fi

if [[ -e "$OUTPUT_FILE" ]]; then
  echo "error: output already exists: $OUTPUT_FILE" >&2
  echo "Refusing to overwrite an existing encrypted secret automatically." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
PLAIN="$TMPDIR/firecrawl-secret.yaml"

python3 - "$ENV_FILE" "$PLAIN" <<'PY'
import sys
from pathlib import Path

env_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

values = {}
for raw in env_path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[7:].lstrip()
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    key = key.strip()
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        value = value[1:-1]
    values[key] = value

# Preserve Docker Compose-compatible internal DB defaults when they are not in .env.
values.setdefault("POSTGRES_USER", "firecrawl")
values.setdefault("POSTGRES_PASSWORD", "firecrawl_password")
values.setdefault("POSTGRES_DB", "firecrawl")

allowed = [
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "MODEL_NAME",
    "MODEL_EMBEDDING_NAME",
    "OLLAMA_BASE_URL",
    "SLACK_WEBHOOK_URL",
    "BULL_AUTH_KEY",
    "TEST_API_KEY",
    "SELF_HOSTED_WEBHOOK_URL",
    "PROXY_SERVER",
    "PROXY_USERNAME",
    "PROXY_PASSWORD",
    "SEARXNG_ENDPOINT",
    "SEARXNG_ENGINES",
    "SEARXNG_CATEGORIES",
    "NUQ_BACKEND",
]

selected = {k: values[k] for k in allowed if values.get(k, "") != ""}

required = ["POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"]
missing = [k for k in required if not selected.get(k)]
if missing:
    raise SystemExit("required Firecrawl values missing: " + ", ".join(missing))

def yaml_quote(value: str) -> str:
    # JSON string syntax is valid YAML and safely preserves special characters.
    import json
    return json.dumps(value, ensure_ascii=False)

lines = [
    "apiVersion: v1",
    "kind: Secret",
    "metadata:",
    "  name: firecrawl-secrets",
    "  namespace: firecrawl",
    "type: Opaque",
    "stringData:",
]
for key in allowed:
    if key in selected:
        lines.append(f"  {key}: {yaml_quote(selected[key])}")

out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

sops --encrypt --config .sops.yaml "$PLAIN" > "$OUTPUT_FILE"
chmod 0600 "$OUTPUT_FILE"

# Validate decryptability without printing plaintext.
sops --decrypt "$OUTPUT_FILE" >/dev/null

echo "Encrypted Firecrawl Secret created: $OUTPUT_FILE"
echo "Values were not printed and plaintext was only held in a temporary directory."
echo "Next: make secret-validate FILE=$OUTPUT_FILE"
echo "Then: make secret-apply FILE=$OUTPUT_FILE"
