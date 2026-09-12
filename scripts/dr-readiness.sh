#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${K3S_BACKUP_DIR:-/srv/k3s/backups/k3s}"
CONFIG_DIR="${RESTIC_CONFIG_DIR:-/etc/k3s-backup}"
SOPS_FILE="${RESTIC_R2_SOPS_FILE:-$REPO_ROOT/secrets/restic-r2.sops.yaml}"

[[ ${EUID} -eq 0 ]] || { echo "error: this readiness check must run as root" >&2; exit 1; }

ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILED=1; }
info() { printf '[INFO] %s\n' "$*"; }

FAILED=0

printf 'Disaster recovery readiness check (read-only)\n\n'

for cmd in git ansible-playbook terraform sops age restic kubectl python3 sha256sum tar; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "command available: $cmd"
  else
    fail "command missing: $cmd"
  fi
done

if [[ -d "$REPO_ROOT/.git" ]]; then
  ok "repository checkout detected"
else
  fail "repository checkout not detected at $REPO_ROOT"
fi

for path in \
  "$REPO_ROOT/ansible/playbooks/bootstrap.yml" \
  "$REPO_ROOT/ansible/playbooks/k3s.yml" \
  "$REPO_ROOT/terraform/r2/main.tf" \
  "$REPO_ROOT/scripts/k3s-backup-verify.sh"; do
  [[ -f "$path" ]] && ok "required repository artifact: ${path#$REPO_ROOT/}" || fail "missing repository artifact: ${path#$REPO_ROOT/}"
done

if [[ -s "$SOPS_FILE" ]]; then
  ok "encrypted Restic/R2 configuration exists"
  if sudo -u "${SUDO_USER:-root}" sops --decrypt "$SOPS_FILE" >/dev/null 2>&1; then
    ok "SOPS file can be decrypted with the current age identity"
  else
    fail "SOPS file cannot be decrypted with the current age identity"
  fi
else
  fail "encrypted Restic/R2 configuration missing: $SOPS_FILE"
fi

for file in "$CONFIG_DIR/restic.repository" "$CONFIG_DIR/restic.password" "$CONFIG_DIR/r2.env"; do
  if [[ -s "$file" ]]; then
    ok "runtime backup configuration present: $file"
  else
    fail "runtime backup configuration missing: $file"
  fi
done

if [[ -s "$CONFIG_DIR/restic.repository" && -s "$CONFIG_DIR/restic.password" && -s "$CONFIG_DIR/r2.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_DIR/r2.env"
  set +a
  export RESTIC_REPOSITORY_FILE="$CONFIG_DIR/restic.repository"
  export RESTIC_PASSWORD_FILE="$CONFIG_DIR/restic.password"

  if restic snapshots --tag k3s-control-plane --latest 1 >/tmp/dr-readiness-restic.$$ 2>/dev/null; then
    if grep -q 'k3s-control-plane' /tmp/dr-readiness-restic.$$; then
      ok "at least one K3s control-plane snapshot is readable from R2"
    else
      fail "R2 repository is reachable but no K3s control-plane snapshot was found"
    fi
  else
    fail "unable to read Restic snapshots from R2"
  fi
  rm -f /tmp/dr-readiness-restic.$$
fi

LATEST="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
if [[ -n "$LATEST" ]]; then
  ok "latest local K3s backup found: $(basename "$LATEST")"
  if bash "$REPO_ROOT/scripts/k3s-backup-verify.sh" "$LATEST" >/dev/null; then
    ok "latest local K3s backup passes restore rehearsal"
  else
    fail "latest local K3s backup failed restore rehearsal"
  fi
else
  fail "no local K3s backup found under $BACKUP_DIR"
fi

AGE_KEY="${SOPS_AGE_KEY_FILE:-${SUDO_USER:+/home/$SUDO_USER/.config/sops/age/keys.txt}}"
if [[ -n "$AGE_KEY" && -s "$AGE_KEY" ]]; then
  ok "age identity exists locally"
  info "the age private identity itself must also have an independent off-host recovery copy"
else
  info "age identity path was not detected automatically; verify its off-host recovery copy manually"
fi

printf '\n'
if (( FAILED )); then
  echo "Disaster recovery readiness: NOT READY"
  exit 1
fi

echo "Disaster recovery readiness: READY FOR A SEPARATE RESTORE REHEARSAL"
echo "No live K3s state or backup data was modified by this check."
