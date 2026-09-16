#!/usr/bin/env bash
set -euo pipefail

TF_DIR="terraform/cloudflare"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN is not set." >&2
  exit 1
fi

if [[ ! -f "${TF_DIR}/terraform.tfvars" ]]; then
  echo "${TF_DIR}/terraform.tfvars is missing." >&2
  echo "Copy terraform.tfvars.example to terraform.tfvars and fill the discovered IDs first." >&2
  exit 1
fi

terraform -chdir="${TF_DIR}" init -input=false >/dev/null

read_var() {
  local name="$1"
  terraform -chdir="${TF_DIR}" console <<EOF | tr -d '"\r'
var.${name}
EOF
}

ACCOUNT_ID="$(read_var cloudflare_account_id)"
ZONE_ID="$(read_var cloudflare_zone_id)"
TUNNEL_ID="$(read_var cloudflare_tunnel_id)"
WILDCARD_RECORD_ID="$(read_var cloudflare_wildcard_record_id)"

if [[ -z "${ACCOUNT_ID}" || -z "${ZONE_ID}" || -z "${TUNNEL_ID}" || -z "${WILDCARD_RECORD_ID}" ]]; then
  echo "One or more required Terraform variables are empty." >&2
  exit 1
fi

import_if_missing() {
  local address="$1"
  local id="$2"

  if terraform -chdir="${TF_DIR}" state show "${address}" >/dev/null 2>&1; then
    echo "Already imported: ${address}"
    return
  fi

  echo "Importing ${address}"
  terraform -chdir="${TF_DIR}" import "${address}" "${id}"
}

import_if_missing \
  cloudflare_zero_trust_tunnel_cloudflared.homelab \
  "${ACCOUNT_ID}/${TUNNEL_ID}"

import_if_missing \
  cloudflare_zero_trust_tunnel_cloudflared_config.homelab \
  "${ACCOUNT_ID}/${TUNNEL_ID}"

import_if_missing \
  cloudflare_dns_record.wildcard \
  "${ZONE_ID}/${WILDCARD_RECORD_ID}"

echo
echo "Import complete. No Cloudflare resource was created or modified."
echo "Next step: terraform -chdir=${TF_DIR} plan"
