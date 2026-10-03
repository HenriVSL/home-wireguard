#!/bin/bash
# Pull the latest CI-tested image and recreate the container if it changed.
# Rolls back to the previous image if the new one does not become healthy.
# Run weekly from cron; safe to run by hand any time.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

log() { echo "$(date '+%F %T') $*"; }

image=$(docker compose config --images | head -1)
old=$(docker inspect -f '{{.Image}}' wireguard 2>/dev/null || true)

docker compose pull -q
new=$(docker image inspect -f '{{.Id}}' "$image")

if [[ "$old" == "$new" ]]; then
  log "up to date ($image)"
  exit 0
fi

wait_healthy() {
  local status
  for _ in $(seq 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' wireguard 2>/dev/null || true)
    [[ "$status" == healthy ]] && return 0
    sleep 2
  done
  return 1
}

log "updating ${old:0:19} -> ${new:0:19}"
docker compose up -d
if wait_healthy; then
  [[ -n "$old" ]] && docker image rm "$old" >/dev/null 2>&1 || true
  log "update ok"
  exit 0
fi

log "new image unhealthy; last logs:"
docker logs --tail 20 wireguard 2>&1 || true
if [[ -n "$old" ]]; then
  docker tag "$old" "$image"
  docker compose up -d
  wait_healthy && log "rolled back to ${old:0:19}" || log "ROLLBACK ALSO UNHEALTHY"
fi
exit 1
