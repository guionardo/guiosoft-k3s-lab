#!/usr/bin/env bash
set -euo pipefail

# Manage the htpasswd credential for the LAN-only OCI registry.
#
# SOPS operations run on a remote host (where the age identity lives); the
# private key never touches this workstation. Plaintext passwords are held in
# memory only and are never written to disk, printed alongside log messages,
# or committed to git (both files are SOPS-encrypted).
#
# The material is split so plaintext never reaches the cluster:
#   - registry-htpasswd.sops.yaml  -> the DEPLOYED Secret (single key: htpasswd)
#   - registry-passwords.sops.yaml -> plaintext passwords (NOT in the
#                                     kustomization, so Flux never applies it)

SOPS_REMOTE="${REGISTRY_SOPS_SSH:-guionardo@192.168.88.9}"
REGISTRY_HOST="registry.guiosoft.info"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SOPS_CONFIG="${REPO_ROOT}/.sops.yaml"
SECRET_FILE="${REPO_ROOT}/kubernetes/secrets/registry/registry-htpasswd.sops.yaml"
PASSWORDS_FILE="${REPO_ROOT}/kubernetes/secrets/registry/registry-passwords.sops.yaml"
KUSTOMIZATION_FILE="${REPO_ROOT}/kubernetes/secrets/registry/kustomization.yaml"

error() {
  echo "error: $*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  scripts/registry-credentials.sh generate
  scripts/registry-credentials.sh validate
  scripts/registry-credentials.sh login
  scripts/registry-credentials.sh password <pusher|puller>
EOF
}

# Read the single age recipient from .sops.yaml (never hardcoded).
read_recipient() {
  local rec count
  rec="$(grep -Eo 'age1[A-Za-z0-9]+' "${SOPS_CONFIG}" | sort -u)"
  count="$(printf '%s\n' "${rec}" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "${count}" -ne 1 ]]; then
    error "expected exactly one age recipient in ${SOPS_CONFIG}, found ${count}"
    exit 1
  fi
  printf '%s' "${rec}"
}

sops_encrypt() {
  ssh "${SOPS_REMOTE}" "sops --encrypt --input-type yaml --output-type yaml --age ${1} --encrypted-regex '^(data|stringData)$' /dev/stdin"
}

sops_decrypt() {
  ssh "${SOPS_REMOTE}" "sops --decrypt --input-type yaml --output-type yaml /dev/stdin"
}

generate() {
  local recipient pusher_pw puller_pw pusher_line puller_line htpasswd_manifest pw_manifest tmpdir

  recipient="$(read_recipient)"

  pusher_pw="$(openssl rand -hex 32)"
  puller_pw="$(openssl rand -hex 32)"
  pusher_line="$(htpasswd -nbB pusher "${pusher_pw}")"
  puller_line="$(htpasswd -nbB puller "${puller_pw}")"

  mkdir -p "$(dirname "${SECRET_FILE}")"

  # Deployed Secret: exactly one key, htpasswd. Plaintext never touches disk.
  htpasswd_manifest="$(printf '%s\n' \
    'apiVersion: v1' \
    'kind: Secret' \
    'metadata:' \
    '  name: registry-htpasswd' \
    '  namespace: registry' \
    'type: Opaque' \
    'stringData:' \
    '  htpasswd: |' \
    "    ${pusher_line}" \
    "    ${puller_line}")"

  # Non-deployed helper: plaintext passwords, kept out of the Flux kustomization.
  pw_manifest="$(printf '%s\n' \
    'apiVersion: v1' \
    'kind: Secret' \
    'metadata:' \
    '  name: registry-passwords' \
    '  namespace: registry' \
    'type: Opaque' \
    'stringData:' \
    "  pusher-password: ${pusher_pw}" \
    "  puller-password: ${puller_pw}")"

  # Encrypt to a temp dir first so a failed round-trip never leaves a truncated
  # ciphertext in place of a valid Secret.
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/registry-credentials.XXXXXX")"
  trap 'rm -rf "${tmpdir}"' EXIT

  printf '%s\n' "${htpasswd_manifest}" | sops_encrypt "${recipient}" > "${tmpdir}/registry-htpasswd.sops.yaml"
  printf '%s\n' "${pw_manifest}" | sops_encrypt "${recipient}" > "${tmpdir}/registry-passwords.sops.yaml"

  mv "${tmpdir}/registry-htpasswd.sops.yaml" "${SECRET_FILE}"
  mv "${tmpdir}/registry-passwords.sops.yaml" "${PASSWORDS_FILE}"
  rm -rf "${tmpdir}"
  trap - EXIT
  chmod 0644 "${SECRET_FILE}" "${PASSWORDS_FILE}"

  printf 'Encrypted registry htpasswd secret written to %s\n' "${SECRET_FILE}"
  printf 'Encrypted registry passwords (not deployed) written to %s\n' "${PASSWORDS_FILE}"
}

validate() {
  local field val dec_htpasswd dec_pw typ htpasswd_content pusher_pw puller_pw tmp

  [[ -f "${SECRET_FILE}" ]] || { error "secret file not found: ${SECRET_FILE}"; exit 1; }
  [[ -f "${PASSWORDS_FILE}" ]] || { error "passwords file not found: ${PASSWORDS_FILE}"; exit 1; }

  # Committed ciphertext must keep the top-level object fields readable so
  # Kustomize can still see apiVersion/kind/type without decrypting.
  for field in apiVersion kind type; do
    val="$(grep -E "^${field}:" "${SECRET_FILE}" | head -n1 || true)"
    if [[ -z "${val}" || "${val}" == *"ENC["* ]]; then
      error "${SECRET_FILE}: top-level '${field}' must be readable (got: ${val:-<missing>})"
      exit 1
    fi
  done

  dec_htpasswd="$(sops_decrypt < "${SECRET_FILE}")"

  typ="$(printf '%s\n' "${dec_htpasswd}" | awk '$1 == "type:" { print $2 }')"
  if [[ "${typ}" != "Opaque" ]]; then
    error "expected type: Opaque, got: ${typ:-<missing>}"
    exit 1
  fi

  printf '%s\n' "${dec_htpasswd}" | grep -qE '^[[:space:]]*pusher:' || { error "user 'pusher' not found in htpasswd content"; exit 1; }
  printf '%s\n' "${dec_htpasswd}" | grep -qE '^[[:space:]]*puller:' || { error "user 'puller' not found in htpasswd content"; exit 1; }

  # Deployed Secret must carry exactly one key: htpasswd (no plaintext password keys).
  printf '%s\n' "${dec_htpasswd}" | grep -qE '^[[:space:]]*htpasswd:' || { error "key 'htpasswd' not found in deployed Secret"; exit 1; }
  if printf '%s\n' "${dec_htpasswd}" | grep -qE '^[[:space:]]*[A-Za-z0-9_-]+-password:'; then
    error "deployed Secret must not contain plaintext password keys"
    exit 1
  fi

  # Passwords file (never applied by Flux) holds the two plaintext password keys.
  dec_pw="$(sops_decrypt < "${PASSWORDS_FILE}")"
  printf '%s\n' "${dec_pw}" | grep -qE '^[[:space:]]*pusher-password:' || { error "key 'pusher-password' not found in passwords file"; exit 1; }
  printf '%s\n' "${dec_pw}" | grep -qE '^[[:space:]]*puller-password:' || { error "key 'puller-password' not found in passwords file"; exit 1; }

  # kustomization.yaml must list the deployed Secret and exclude the passwords file.
  grep -qE 'registry-htpasswd\.sops\.yaml' "${KUSTOMIZATION_FILE}" || { error "${KUSTOMIZATION_FILE} must list registry-htpasswd.sops.yaml"; exit 1; }
  if grep -qE 'registry-passwords\.sops\.yaml' "${KUSTOMIZATION_FILE}"; then
    error "${KUSTOMIZATION_FILE} must NOT list registry-passwords.sops.yaml"
    exit 1
  fi

  # Prove correspondence: each decrypted plaintext password must verify against
  # its decrypted bcrypt hash. bcrypt hashes are not secret; the htpasswd lines
  # are staged in a mktemp file so htpasswd -vb can check them without any
  # plaintext touching a non-temporary file.
  htpasswd_content="$(printf '%s\n' "${dec_htpasswd}" | grep -E '^[[:space:]]+(pusher|puller):' | sed 's/^[[:space:]]*//')"
  pusher_pw="$(printf '%s\n' "${dec_pw}" | awk '$1 == "pusher-password:" { print $2 }')"
  puller_pw="$(printf '%s\n' "${dec_pw}" | awk '$1 == "puller-password:" { print $2 }')"

  tmp="$(mktemp "${TMPDIR:-/tmp}/registry-htpasswd-check.XXXXXX")"
  trap 'rm -f "${tmp}"' EXIT
  printf '%s\n' "${htpasswd_content}" > "${tmp}"

  htpasswd -vb "${tmp}" pusher "${pusher_pw}" >/dev/null 2>&1 || { error "password for 'pusher' does not match the deployed htpasswd hash"; exit 1; }
  htpasswd -vb "${tmp}" puller "${puller_pw}" >/dev/null 2>&1 || { error "password for 'puller' does not match the deployed htpasswd hash"; exit 1; }

  rm -f "${tmp}"
  trap - EXIT

  printf 'Valid encrypted registry htpasswd secret: %s\n' "${SECRET_FILE}"
  printf 'Valid registry passwords file (not deployed): %s\n' "${PASSWORDS_FILE}"
}

login() {
  printf 'docker login %s -u pusher\n' "${REGISTRY_HOST}"
}

password() {
  local user="$1" dec pw

  [[ -f "${PASSWORDS_FILE}" ]] || { error "passwords file not found: ${PASSWORDS_FILE}"; exit 1; }

  dec="$(sops_decrypt < "${PASSWORDS_FILE}")"
  pw="$(printf '%s\n' "${dec}" | awk -v k="${user}-password:" '$1 == k { print $2 }')"
  if [[ -z "${pw}" ]]; then
    error "password for user '${user}' not found in ${PASSWORDS_FILE}"
    exit 1
  fi

  # Only the password on stdout; nothing else (callers use this in $(...)).
  printf '%s\n' "${pw}"
}

ACTION="${1:-}"

case "${ACTION}" in
  generate) generate ;;
  validate) validate ;;
  login) login ;;
  password)
    USER="${2:-}"
    if [[ "${USER}" != "pusher" && "${USER}" != "puller" ]]; then
      usage >&2
      exit 2
    fi
    password "${USER}"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
