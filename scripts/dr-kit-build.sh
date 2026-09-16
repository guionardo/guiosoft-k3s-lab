#!/usr/bin/env bash
set -euo pipefail
OUT="${1:-}"; REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; [[ -n "$OUT" ]] || { echo "usage: $0 /path/to/dr-kit" >&2; exit 2; }; command -v sha256sum >/dev/null || exit 1; command -v git >/dev/null || exit 1; [[ ! -e "$OUT" ]] || { echo "error: output exists: $OUT" >&2; exit 1; }
# Provenance must describe exactly committed recovery tooling, not an arbitrary
# dirty working tree whose files merely happen to hash consistently afterward.
if ! git -C "$REPO_ROOT" diff --quiet -- scripts ansible || ! git -C "$REPO_ROOT" diff --cached --quiet -- scripts ansible; then echo "error: recovery tooling/ansible working tree is dirty; commit or revert it before building a DR kit" >&2; exit 1; fi
install -d -m 0700 "$OUT/scripts" "$OUT/ansible"
scripts=(dr-target-init.sh dr-target-reset.sh dr-network-isolation.sh dr-preflight.sh dr-rehearsal-status.sh dr-restore-k3s.sh k3s-backup-verify.sh dr-neutralize.sh dr-pv-import.sh dr-pv-remap.sh dr-oci-preload.sh dr-kit-verify.sh dr-bundle-verify.sh dr-recover.sh)
for name in "${scripts[@]}"; do src="$REPO_ROOT/scripts/$name"; [[ -s "$src" ]] || { echo "error: required recovery script missing: $src" >&2; exit 1; }; install -m 0755 "$src" "$OUT/scripts/$name"; done
[[ -d "$REPO_ROOT/ansible" ]] || { echo "error: ansible directory missing" >&2; exit 1; }; tar -C "$REPO_ROOT" --exclude='ansible/inventory' --exclude='*.retry' -cf - ansible | tar -C "$OUT" -xf -
commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"; tree="$(git -C "$REPO_ROOT" rev-parse HEAD^{tree})"; cat >"$OUT/MANIFEST" <<EOF
format=guiosoft-k3s-dr-kit-v1
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_commit=$commit
source_tree=$tree
builder_host=$(hostname -s)
EOF
cat >"$OUT/README.txt" <<'EOF'
guiosoft-k3s-lab offline DR tooling kit

Contains the complete isolated recovery toolchain, bundle verifier and checkpointed recovery orchestrator. It intentionally contains no plaintext credentials, private age identity, K3s server token, Restic password, or R2 secret keys. Verify SHA256SUMS before use. GitHub access is not required after materialization.
EOF
( cd "$OUT"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS; sha256sum -c SHA256SUMS >/dev/null ); chmod 0600 "$OUT/MANIFEST" "$OUT/README.txt" "$OUT/SHA256SUMS"; echo "Offline DR tooling kit built and verified: $OUT"; echo "source_commit=$commit"
