#!/usr/bin/env bash
# End-to-end test: real WireGuard tunnels between containers.
#
#   tests/e2e.sh <new-image> [previous-image]
#
# Topology (docker networks):
#   wan  172.31.10.0/24  server + client    (stands in for the internet)
#   lan  172.31.20.0/24  server + lanhost + dns (stands in for the home LAN)
#   ext  172.31.30.0/24  server + exthost   (stands in for "the rest of the internet")
#
# The client is only on wan, so reaching lan/ext proves traffic went through
# the tunnel. The lan profile must reach lan but NOT ext; full must reach both.
#
# Upgrade check: if previous-image is given (the currently published release),
# the client is created with it, then the server is recreated from new-image on
# the same /data and the *old* profile must still work unchanged.

set -euo pipefail

NEW=${1:?usage: e2e.sh <new-image> [previous-image]}
PREV=${2:-}
P=wge2e
SERVER_WAN=172.31.10.2
LANHOST=172.31.20.10
DNS=172.31.20.53
EXTHOST=172.31.30.10
DATA_VOL=$P-data
STATE_VOL=$P-state
WEBPW=correct-horse-e2e
WEB=http://$SERVER_WAN:8080

pass=0
fail=0
ok()   { echo "  PASS  $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
check_not() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi; }

cleanup() {
  docker rm -f $P-server $P-client $P-lanhost $P-exthost $P-dns >/dev/null 2>&1 || true
  docker network rm $P-wan $P-lan $P-ext >/dev/null 2>&1 || true
  docker volume rm $DATA_VOL $STATE_VOL >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

dump_logs() {
  echo "----- server logs -----"
  docker logs $P-server 2>&1 | tail -50 || true
}

docker network create --subnet 172.31.10.0/24 $P-wan >/dev/null
docker network create --subnet 172.31.20.0/24 $P-lan >/dev/null
docker network create --subnet 172.31.30.0/24 $P-ext >/dev/null
docker volume create $DATA_VOL >/dev/null
docker volume create $STATE_VOL >/dev/null

docker run -d --name $P-lanhost --network $P-lan --ip $LANHOST alpine:3 sleep infinity >/dev/null
docker run -d --name $P-exthost --network $P-ext --ip $EXTHOST alpine:3 sleep infinity >/dev/null
docker run -d --name $P-dns --network $P-lan --ip $DNS alpine:3 \
  sh -c 'apk add -q --no-cache dnsmasq && exec dnsmasq -k --no-resolv --log-facility=- --address=/test.home/10.99.99.99' >/dev/null

start_server() {
  local image=$1
  docker rm -f $P-server >/dev/null 2>&1 || true
  docker create --name $P-server \
    --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 \
    --network $P-wan --ip $SERVER_WAN \
    -e WG_HOST=$SERVER_WAN -e WG_PORT=51820 \
    -e WG_DNS=$DNS -e WG_LAN_ROUTES=172.31.20.0/24 \
    -e WEB_PASSWORD=$WEBPW \
    -v $DATA_VOL:/data -v $STATE_VOL:/state:ro "$image" >/dev/null
  docker network connect --ip 172.31.20.2 $P-lan $P-server
  docker network connect --ip 172.31.30.2 $P-ext $P-server
  docker start $P-server >/dev/null
  for _ in $(seq 30); do
    [[ "$(docker inspect -f '{{.State.Health.Status}}' $P-server)" == healthy ]] && return 0
    [[ "$(docker inspect -f '{{.State.Running}}' $P-server)" == true ]] || break
    sleep 1
  done
  dump_logs
  echo "server ($image) did not become healthy"
  exit 1
}

# Client: same image (has wg-quick), no resolvconf so the DNS line is stripped
# and DNS is tested by querying the pushed server explicitly.
docker run -d --name $P-client --cap-add NET_ADMIN \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --sysctl net.ipv6.conf.all.disable_ipv6=0 \
  --network $P-wan --ip 172.31.10.3 --entrypoint sleep "$NEW" infinity >/dev/null
docker exec $P-client apk add -q --no-cache bind-tools curl >/dev/null

client() { docker exec $P-client "$@"; }

tunnel_up() {  # $1 = profile text
  grep -v '^DNS' <<<"$1" | docker exec -i $P-client sh -c 'cat > /etc/wireguard/wgc.conf && chmod 600 /etc/wireguard/wgc.conf'
  client wg-quick up wgc >/dev/null 2>&1
}
tunnel_down() { client wg-quick down wgc >/dev/null 2>&1 || true; }

test_profiles() {  # $1 = label, $2 = full profile, $3 = lan profile
  local label=$1 full=$2 lan=$3

  echo "[$label] profile contents"
  check "full routes everything"        grep -qx 'AllowedIPs = 0.0.0.0/0, ::/0' <<<"$full"
  check "lan routes vpn + lan only"     grep -qx 'AllowedIPs = 10.66.66.0/24, 172.31.20.0/24' <<<"$lan"
  check "full pushes DNS"               grep -qx "DNS = $DNS" <<<"$full"
  check "lan pushes DNS"                grep -qx "DNS = $DNS" <<<"$lan"
  check "endpoint is WG_HOST:WG_PORT"   grep -qx "Endpoint = $SERVER_WAN:51820" <<<"$full"

  echo "[$label] lan profile"
  check_not "no route to lan before tunnel" client ping -c1 -W1 $LANHOST
  tunnel_up "$lan"
  check     "handshake + reach lan host"    client ping -c3 -W2 $LANHOST
  check     "reach server tunnel address"   client ping -c1 -W2 10.66.66.1
  check     "DNS server answers via tunnel" sh -c "docker exec $P-client dig +short +time=2 +tries=2 @$DNS test.home | grep -qx 10.99.99.99"
  check_not "does NOT route other traffic"  client ping -c2 -W1 $EXTHOST
  tunnel_down

  echo "[$label] full profile"
  tunnel_up "$full"
  check "reach lan host"                client ping -c3 -W2 $LANHOST
  check "reach outside host via server" client ping -c3 -W2 $EXTHOST
  check "default route is the tunnel"   sh -c "docker exec $P-client ip route get $EXTHOST | grep -q 'dev wgc'"
  check "DNS server answers via tunnel" sh -c "docker exec $P-client dig +short +time=2 +tries=2 @$DNS test.home | grep -qx 10.99.99.99"
  tunnel_down
}

profile() { docker exec $P-server cat "/data/clients/$1/$1-$2.conf"; }

# ---------------------------------------------------------------- phase 1
FIRST=$NEW
if [[ -n "$PREV" ]] && docker pull -q "$PREV" >/dev/null 2>&1; then
  FIRST=$PREV
  echo "== phase 1: previous release $PREV"
else
  echo "== phase 1: new image (no previous release to upgrade from)"
fi
start_server "$FIRST"
docker exec $P-server wgctl add ci >/dev/null
check "QR codes generated" docker exec $P-server test -s /data/clients/ci/ci-full.png -a -s /data/clients/ci/ci-lan.png
OLD_FULL=$(profile ci full)
OLD_LAN=$(profile ci lan)
OLD_SERVER_KEY=$(docker exec $P-server cat /data/server/public.key)
test_profiles "phase1" "$OLD_FULL" "$OLD_LAN"

# ---------------------------------------------------------------- phase 2
echo "== phase 2: recreate server from $NEW on the same data"
start_server "$NEW"
check "server key survived recreate" test "$(docker exec $P-server cat /data/server/public.key)" = "$OLD_SERVER_KEY"
check "full profile unchanged"        test "$(profile ci full)" = "$OLD_FULL"
check "lan profile unchanged"         test "$(profile ci lan)" = "$OLD_LAN"
test_profiles "phase2 (old profiles)" "$OLD_FULL" "$OLD_LAN"

echo "[phase2] client management"
docker exec $P-server wgctl add tmp >/dev/null
TMP_PUB=$(docker exec $P-server cat /data/clients/tmp/public.key)
check     "added peer is live without restart" sh -c "docker exec $P-server wg show wg0 peers | grep -qx '$TMP_PUB'"
check     "second client gets next address"    sh -c "docker exec $P-server cat /data/clients/tmp/ip | grep -qx 10.66.66.3"
check_not "duplicate name rejected"            docker exec $P-server wgctl add tmp
check_not "bad name rejected"                  docker exec $P-server wgctl add 'a;b'
check     "list shows clients"                 sh -c "docker exec $P-server wgctl list | grep -q '^tmp '"
docker exec $P-server wgctl remove tmp >/dev/null
check_not "removed peer is gone"               sh -c "docker exec $P-server wg show wg0 peers | grep -qx '$TMP_PUB'"
tunnel_up "$OLD_LAN"
check     "other client unaffected by remove"  client ping -c2 -W2 $LANHOST
tunnel_down

echo "[phase2] web page"
# curl from the client container; jar keeps the session cookie
web() { docker exec $P-client curl -s -m 10 -b /tmp/jar -c /tmp/jar "$@"; }
code() { web -o /dev/null -w '%{http_code}' "$@"; }
check     "redirects to login when logged out"   test "$(code $WEB/)" = 303
check     "wrong password refused"               test "$(code -d password=nope $WEB/login)" = 401
check     "right password logs in"               test "$(code -d password=$WEBPW $WEB/login)" = 303
check     "session cookie is HttpOnly+Strict"    sh -c "docker exec $P-client curl -s -D - -o /dev/null -d password=$WEBPW $WEB/login | grep -i '^set-cookie' | grep -qi 'httponly.*samesite=strict'"
check     "device list shows existing client"    sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/ | grep -q '>ci<'"
check     "add device via web"                   test "$(code -d name=webdev $WEB/add)" = 303
check     "web-added peer is live"               sh -c "docker exec $P-server wg show wg0 peers | grep -qx \"\$(docker exec $P-server cat /data/clients/webdev/public.key)\""
check     "download full profile"                sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/d/webdev/full.conf | grep -qx 'AllowedIPs = 0.0.0.0/0, ::/0'"
check     "download lan profile"                 sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/d/webdev/lan.conf | grep -qx 'AllowedIPs = 10.66.66.0/24, 172.31.20.0/24'"
check     "QR image served as PNG"               sh -c "docker exec $P-client curl -s -b /tmp/jar -o /dev/null -w '%{content_type}' $WEB/d/webdev/lan.png | grep -q image/png"
check     "invalid name rejected"                sh -c "docker exec $P-client curl -s -b /tmp/jar -o /dev/null -w '%{redirect_url}' -d 'name=a/b' $WEB/add | grep -q error="
check     "path traversal refused"               test "$(code "$WEB/d/..%2Fserver/full.conf")" = 404
check     "cross-site POST refused"              test "$(code -H 'Origin: http://evil.example' -d name=evil $WEB/add)" = 403
check_not "cross-site POST created nothing"      docker exec $P-server test -e /data/clients/evil
check     "no access without cookie"             test "$(docker exec $P-client curl -s -o /dev/null -w '%{http_code}' $WEB/d/webdev/full.conf)" = 303
check     "remove device via web"                test "$(code -X POST $WEB/d/webdev/remove)" = 303
check_not "web-removed device is gone"           docker exec $P-server test -e /data/clients/webdev
check     "logout ends session"                  sh -c "test \"\$(docker exec $P-client curl -s -b /tmp/jar -c /tmp/jar -o /dev/null -w '%{http_code}' -X POST $WEB/logout)\" = 303 && test \"\$(docker exec $P-client curl -s -b /tmp/jar -o /dev/null -w '%{http_code}' $WEB/)\" = 303"

echo "[phase2] status section"
page() { docker exec $P-client curl -s -b /tmp/jar "$WEB/"; }
web -o /dev/null -d password=$WEBPW $WEB/login
check     "shows status card"                    sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/ | grep -q '<h2>Status</h2>'"
check     "shows component versions"             sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/ | grep -q 'wireguard-tools v'"
check     "no update yet -> info note"           sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/ | grep -q 'No automatic update has run yet'"
# Simulate what update.sh writes after a failed update (container sees it read-only)
docker run --rm -v $STATE_VOL:/state alpine:3 sh -c \
  'echo "{\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"result\":\"rolled-back\",\"message\":\"New version did not start\"}" > /state/last-check.json'
check     "failed update -> error note"          sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/ | grep -q 'note error.*New version did not start'"
docker run --rm -v $STATE_VOL:/state alpine:3 sh -c \
  'echo "{\"time\":\"2020-01-01T00:00:00Z\",\"result\":\"up-to-date\",\"message\":\"ok\"}" > /state/last-check.json'
check     "stale update check -> warning"        sh -c "docker exec $P-client curl -s -b /tmp/jar $WEB/ | grep -q 'note warn.*have.*t run since'"
check_not "state dir is read-only for server"    docker exec $P-server touch /state/x

echo "[phase2] clean shutdown"
docker stop -t 10 $P-server >/dev/null
check "exits 0 on SIGTERM" test "$(docker inspect -f '{{.State.ExitCode}}' $P-server)" = 0

echo
echo "passed: $pass  failed: $fail"
if (( fail > 0 )); then dump_logs; exit 1; fi
