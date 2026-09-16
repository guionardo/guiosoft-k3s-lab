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
echo "Container runtime limits and immutable image identity:"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  inspect="$(docker inspect "$name")"
  image_ref="$(jq -r '.[0].Config.Image' <<<"$inspect")"
  image_id="$(jq -r '.[0].Image' <<<"$inspect")"
  cpus="$(jq -r '.[0].HostConfig.NanoCpus // 0 | if . == 0 then "unlimited" else ((. / 1000000000) | tostring) end' <<<"$inspect")"
  memory="$(jq -r '.[0].HostConfig.Memory // 0 | if . == 0 then "unlimited" else ((. / 1073741824 * 100 | round) / 100 | tostring + " GiB") end' <<<"$inspect")"
  restart="$(jq -r '.[0].HostConfig.RestartPolicy.Name // ""' <<<"$inspect")"
  printf -- '- %s\n  image=%s\n  image_id=%s\n  cpu=%s\n  memory=%s\n  restart=%s\n' "$name" "$image_ref" "$image_id" "$cpus" "$memory" "$restart"

  repo_digests="$(docker image inspect "$image_id" 2>/dev/null | jq -r '.[0].RepoDigests[]?' | sort -u || true)"
  if [[ -n "$repo_digests" ]]; then
    while IFS= read -r digest; do
      [[ -n "$digest" ]] && echo "  repo_digest=$digest"
    done <<<"$repo_digests"
  else
    echo "  repo_digest=unavailable"
  fi
done < <(jq -r '.[].Names' <<<"$containers_json")

echo
echo "Volume mounts by container:"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  docker inspect "$name" | jq -r '.[0] as $c | ($c.Mounts[]? | "- \($c.Name | ltrimstr("/"))\n  type=\(.Type)\n  source=\(.Source)\n  destination=\(.Destination)\n  rw=\(.RW)")'
done < <(jq -r '.[].Names' <<<"$containers_json")

echo
echo "Mounted data usage (read-only, measured inside containers):"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  while IFS=$'\t' read -r mount_type destination; do
    [[ "$mount_type" == "volume" ]] || continue
    [[ -n "$destination" ]] || continue
    if usage="$(docker exec "$name" du -sh "$destination" 2>/dev/null | awk '{print $1}')" && [[ -n "$usage" ]]; then
      printf -- '- %s %s: %s\n' "$name" "$destination" "$usage"
    else
      printf -- '- %s %s: unavailable (du missing or permission denied)\n' "$name" "$destination"
    fi
  done < <(docker inspect "$name" | jq -r '.[0].Mounts[]? | [.Type, .Destination] | @tsv')
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
echo "- PostgreSQL, Redis and RabbitMQ all have persistent Docker volume mounts in the current runtime."
echo "- PostgreSQL is critical state; Redis and RabbitMQ still need cutover semantics decided before migration."
echo "- API and Playwright are recreatable application/runtime components."
echo "- Use image_id/repo_digest above to pin the Kubernetes staging images to the exact currently tested artifacts."
echo "- Mount mapping above identifies anonymous Docker volumes before cleanup or migration decisions."
echo "- Mounted data usage helps validate proposed PVC capacities without reading secret values."
echo "- Do not run old and new Firecrawl stacks as active writers against copied state simultaneously."
echo "- Secrets/environment values are intentionally not printed by this audit."
echo
echo "Firecrawl migration audit completed. No Docker/Kubernetes resources were changed."
