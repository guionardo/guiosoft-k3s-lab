#!/usr/bin/env bash
# Read-only inventory for the existing Debian host.
# It deliberately avoids reading secret file contents and environment values.
set -uo pipefail

umask 077
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname -s 2>/dev/null || echo unknown)"
OUT_ROOT="${DISCOVERY_OUTPUT_DIR:-discovery-output}"
OUT="${OUT_ROOT}/${HOST}-${TIMESTAMP}"
mkdir -p "$OUT"
REPORT="$OUT/report.md"

have() { command -v "$1" >/dev/null 2>&1; }

section() {
  printf '\n## %s\n\n```text\n' "$1" >> "$REPORT"
}

end_section() { printf '```\n' >> "$REPORT"; }

run() {
  local title="$1"; shift
  section "$title"
  printf '$ %q' "$1" >> "$REPORT"
  local arg
  for arg in "${@:2}"; do printf ' %q' "$arg" >> "$REPORT"; done
  printf '\n\n' >> "$REPORT"
  "$@" >> "$REPORT" 2>&1 || printf '\n[command exited with status %s]\n' "$?" >> "$REPORT"
  end_section
}

run_sh() {
  local title="$1" cmd="$2"
  section "$title"
  printf '$ %s\n\n' "$cmd" >> "$REPORT"
  bash -c "$cmd" >> "$REPORT" 2>&1 || printf '\n[command exited with status %s]\n' "$?" >> "$REPORT"
  end_section
}

cat > "$REPORT" <<EOF
# Debian host discovery

- Generated: $(date --iso-8601=seconds)
- Host: ${HOST}
- User: $(id -un)
- Read-only inventory: yes

> Review this report manually before sharing it or committing sanitized excerpts. Infrastructure metadata can itself be sensitive.
EOF

run "Identity" sh -c 'hostnamectl 2>/dev/null || true; echo; uname -a; echo; cat /etc/os-release 2>/dev/null || true'
run "CPU" lscpu
run "Memory" sh -c 'free -h; echo; grep -E "^(MemTotal|MemAvailable|SwapTotal|SwapFree):" /proc/meminfo'
run "Block devices and filesystems" lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS,MODEL
run "Filesystem usage" df -hT
run_sh "fstab (credentials/options redacted)" "sed -E 's/(password|passwd|credentials|username|user)=([^ ,]+)/\\1=<redacted>/Ig' /etc/fstab 2>/dev/null || true"

run "Network addresses" ip -brief address
run "Routes" ip route
if have resolvectl; then run "DNS" resolvectl status; else run_sh "DNS" "cat /etc/resolv.conf"; fi
run "Listening sockets" ss -lntup

run "Running systemd services" systemctl --no-pager --type=service --state=running
run "Enabled systemd services" systemctl --no-pager list-unit-files --type=service --state=enabled
run "Systemd timers" systemctl --no-pager list-timers --all
run_sh "Cron inventory" "{ ls -la /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly 2>/dev/null; echo; crontab -l 2>/dev/null || true; }"

if have docker; then
  run "Docker version" docker version
  run "Docker containers" docker ps -a --no-trunc
  run "Docker images" docker images --digests
  run "Docker networks" docker network ls
  run "Docker volumes" docker volume ls
  run_sh "Docker Compose projects" "docker compose ls 2>/dev/null || true"
fi
if have podman; then
  run "Podman version" podman version
  run "Podman containers" podman ps -a --no-trunc
  run "Podman images" podman images
  run "Podman volumes" podman volume ls
fi
if have ctr; then run_sh "containerd namespaces" "ctr namespaces list 2>/dev/null || true"; fi

run_sh "Web servers / reverse proxies" "systemctl --no-pager --full status nginx apache2 caddy haproxy 2>/dev/null || true"
run_sh "Database/cache services" "systemctl --no-pager --full status postgresql mysql mariadb mongod mongodb redis-server redis 2>/dev/null || true"

if have nft; then run "nftables" nft list ruleset; fi
if have ufw; then run "UFW" ufw status verbose; fi
if have firewall-cmd; then run "firewalld" firewall-cmd --list-all; fi
if have iptables; then run "iptables" iptables -S; fi

run_sh "Relevant service directories" "for d in /srv /opt /var/www /var/lib/docker/volumes /var/lib/postgresql /var/lib/mysql /var/lib/mongodb; do if [ -e \"\$d\" ]; then echo \"### \$d\"; du -sh \"\$d\" 2>/dev/null || true; find \"\$d\" -maxdepth 2 -mindepth 1 -printf '%y %p\\n' 2>/dev/null | head -n 500; fi; done"

if have cloudflared; then
  run "cloudflared version" cloudflared --version
  run_sh "cloudflared service metadata" "systemctl --no-pager --full status cloudflared 2>/dev/null || true; echo; systemctl cat cloudflared 2>/dev/null | sed -E 's/(--token[= ]+)[^ ]+/\\1<redacted>/Ig; s/(TUNNEL_TOKEN=).*/\\1<redacted>/Ig'"
  run_sh "cloudflared configuration locations (contents NOT read)" "find /etc/cloudflared /root/.cloudflared /home -maxdepth 3 -type f \\( -name 'config.yml' -o -name 'config.yaml' -o -name '*.json' \\) -printf '%p\\n' 2>/dev/null | head -n 200"
else
  run_sh "cloudflared" "echo 'cloudflared binary not found in PATH'"
fi

run_sh "Existing Kubernetes/K3s" "{ command -v k3s 2>/dev/null || true; command -v kubectl 2>/dev/null || true; systemctl --no-pager --full status k3s k3s-agent 2>/dev/null || true; }"
run_sh "Installed packages of interest" "dpkg-query -W -f='${binary:Package}\\t${Version}\\n' 2>/dev/null | grep -Ei 'docker|containerd|podman|cloudflared|nginx|apache|caddy|haproxy|postgres|mysql|maria|mongo|redis|k3s|kube|nftables|ufw|firewalld|ansible|terraform' || true"

cat >> "$REPORT" <<'EOF'

## Notes for manual inventory

The script intentionally does **not** dump:

- process environments;
- `.env` files;
- SSH/private keys;
- Cloudflare credential JSON contents;
- Kubernetes Secrets;
- database contents;
- application configuration files that may contain passwords.

Some information therefore requires manual confirmation later, especially Cloudflare public hostnames/DNS and application-specific dependencies.
EOF

printf 'Discovery complete: %s\n' "$REPORT"
printf 'Do not commit the raw discovery-output directory. Review it first.\n'
