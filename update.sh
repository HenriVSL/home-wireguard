#!/bin/bash
# Pull the latest CI-tested image and recreate the container if it changed.
# Rolls back to the previous image if the new one does not become healthy.
# Run weekly from cron; safe to run by hand any time.
#
# Results are written to ./state (mounted read-only into the container) so the
# web page can show them:
#   state/last-check.json   every run: {time, result, message}
#   state/last-update.json  only when a new image was installed: {time}
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
mkdir -p state

log() { echo "$(date '+%F %T') $*"; }

# $1 = file, $2 = result, $3 = message
write_state() {
  local msg=${3//[\"\\]/}
  printf '{"time":"%s","result":"%s","message":"%s"}\n' "$(date -Iseconds)" "$2" "$msg" > "state/$1.tmp"
  mv "state/$1.tmp" "state/$1"
}

# Any unexpected error (e.g. registry unreachable) is reported as a failed check.
trap 'write_state last-check.json failed "update.sh stopped at line $LINENO"' ERR

image=$(docker compose config --images | head -1)
old=$(docker inspect -f '{{.Image}}' wireguard 2>/dev/null || true)

docker compose pull -q
new=$(docker image inspect -f '{{.Id}}' "$image")

if [[ "$old" == "$new" ]]; then
  log "up to date ($image)"
  write_state last-check.json up-to-date "Already running the latest tested version"
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
  write_state last-update.json updated "Installed new version"
  write_state last-check.json updated "Installed new version"
  exit 0
fi

trap - ERR
log "new image unhealthy; last logs:"
docker logs --tail 20 wireguard 2>&1 || true
if [[ -n "$old" ]]; then
  docker tag "$old" "$image"
  docker compose up -d
  if wait_healthy; then
    log "rolled back to ${old:0:19}"
    write_state last-check.json rolled-back "New version did not start correctly; went back to the previous version"
  else
    log "ROLLBACK ALSO UNHEALTHY"
    write_state last-check.json failed "New version did not start and rollback also failed"
  fi
else
  write_state last-check.json failed "New version did not start correctly and there was no previous version to go back to"
fi
exit 1
