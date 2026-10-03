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

pass=0
fail=0
ok()   { echo "  PASS  $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
check_not() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi; }

cleanup() {
  docker rm -f $P-server $P-client $P-lanhost $P-exthost $P-dns >/dev/null 2>&1 || true
  docker network rm $P-wan $P-lan $P-ext >/dev/null 2>&1 || true
  docker volume rm $DATA_VOL >/dev/null 2>&1 || true
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
    -v $DATA_VOL:/data "$image" >/dev/null
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
docker exec $P-client apk add -q --no-cache bind-tools >/dev/null

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

echo "[phase2] clean shutdown"
docker stop -t 10 $P-server >/dev/null
check "exits 0 on SIGTERM" test "$(docker inspect -f '{{.State.ExitCode}}' $P-server)" = 0

echo
echo "passed: $pass  failed: $fail"
if (( fail > 0 )); then dump_logs; exit 1; fi
