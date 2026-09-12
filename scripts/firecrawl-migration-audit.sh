#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${FIRECRAWL_COMPOSE_PROJECT:-firecrawl}"

need() {
  command -v "$1" >/dev/null || { echo "error: required command not found: $1" >&2; exit 1; }
}

for cmd in docker jq; do
  need "$cmd"
done

printf 'Firecrawl migration audit (read-only)\n\n'

containers_json="$(docker ps --filter "label=com.docker.compose.project=${PROJECT_NAME}" --format '{{json .}}' | jq -s '.')"
count="$(jq 'length' <<<"$containers_json")"

if (( count == 0 )); then
  echo "error: no running containers found for Docker Compose project '${PROJECT_NAME}'" >&2
  echo "Set FIRECRAWL_COMPOSE_PROJECT if the project name differs." >&2
  exit 1
fi

echo "Compose project: ${PROJECT_NAME}"
echo "Running containers: ${count}"
echo
printf '%-40s %-24s %-18s %s\n' NAME IMAGE STATUS PORTS
jq -r '.[] | [.Names, .Image, .Status, .Ports] | @tsv' <<<"$containers_json" \
  | while IFS=$'\t' read -r name image status ports; do
      printf '%-40s %-24s %-18s %s\n' "$name" "$image" "$status" "$ports"
    done

echo
echo "Container runtime limits:"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  inspect="$(docker inspect "$name")"
  image="$(jq -r '.[0].Config.Image' <<<"$inspect")"
  cpus="$(jq -r '.[0].HostConfig.NanoCpus // 0 | if . == 0 then "unlimited" else ((. / 1000000000) | tostring) end' <<<"$inspect")"
  memory="$(jq -r '.[0].HostConfig.Memory // 0 | if . == 0 then "unlimited" else ((. / 1073741824 * 100 | round) / 100 | tostring + " GiB") end' <<<"$inspect")"
  restart="$(jq -r '.[0].HostConfig.RestartPolicy.Name // ""' <<<"$inspect")"
  printf -- '- %s\n  image=%s\n  cpu=%s\n  memory=%s\n  restart=%s\n' "$name" "$image" "$cpus" "$memory" "$restart"
done < <(jq -r '.[].Names' <<<"$containers_json")

echo
echo "Persistent volumes attached to Firecrawl containers:"
volume_names="$({
  while IFS= read -r name; do
    docker inspect "$name" | jq -r '.[0].Mounts[]? | select(.Type == "volume") | .Name'
  done < <(jq -r '.[].Names' <<<"$containers_json")
} | sort -u)"

if [[ -z "$volume_names" ]]; then
  echo "- no Docker named volumes found"
else
  while IFS= read -r volume; do
    [[ -n "$volume" ]] || continue
    docker volume inspect "$volume" | jq -r '.[] | "- \(.Name)\n  mountpoint=\(.Mountpoint)\n  driver=\(.Driver)"'
  done <<<"$volume_names"
fi

echo
echo "Network attachments:"
while IFS= read -r name; do
  docker inspect "$name" | jq -r '.[0] as $c | $c.NetworkSettings.Networks | keys[] | "- \($c.Name | ltrimstr("/")): \(.)"'
done < <(jq -r '.[].Names' <<<"$containers_json")

echo
echo "Host-published ports:"
published="$(jq -r '.[].Ports // empty' <<<"$containers_json" | grep -E '0\.0\.0\.0:|\[::\]:' || true)"
if [[ -n "$published" ]]; then
  printf '%s\n' "$published" | sed 's/^/- /'
else
  echo "- none detected"
fi

echo
echo "Migration interpretation:"
echo "- PostgreSQL and Redis named volumes are stateful and require backup/restore validation before cutover."
echo "- API, Playwright and RabbitMQ can be recreated, but RabbitMQ may contain in-flight queue state during cutover."
echo "- Do not run old and new Firecrawl stacks as active writers against copied state simultaneously."
echo "- Secrets/environment values are intentionally not printed by this audit."
echo
echo "Firecrawl migration audit completed. No Docker/Kubernetes resources were changed."
