# Shared helpers for entrypoint and wgctl.
#
# /data is the only persistent state:
#   /data/server/{private,public}.key
#   /data/clients/<name>/{private.key,public.key,psk,ip}   <- source of truth
#   /data/clients/<name>/<name>-{full,lan}.conf + .png     <- regenerated from env
#
# Client profiles are re-rendered on every start, so changing WG_DNS or
# WG_LAN_ROUTES in .env and restarting updates them (re-import on devices).

set -euo pipefail
umask 077

DATA=/data
WG_CONF=/etc/wireguard/wg0.conf
LISTEN_PORT=51820

: "${WG_HOST:?WG_HOST must be set (public hostname clients connect to)}"
WG_PORT="${WG_PORT:-51820}"
WG_DNS="${WG_DNS:-}"
WG_LAN_ROUTES="${WG_LAN_ROUTES:-192.168.1.0/24}"
WG_SUBNET_PREFIX="${WG_SUBNET_PREFIX:-10.66.66}"
WG_SUBNET="${WG_SUBNET_PREFIX}.0/24"

log() { echo "$(date '+%F %T') $*"; }
die() { echo "error: $*" >&2; exit 1; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

client_dir() { echo "$DATA/clients/$1"; }

client_names() {
  local d
  for d in "$DATA"/clients/*/; do
    [[ -f "$d/public.key" ]] && basename "$d"
  done
  return 0
}

init_server_keys() {
  mkdir -p "$DATA/server" "$DATA/clients"
  if [[ ! -f "$DATA/server/private.key" ]]; then
    log "generating server keys"
    wg genkey > "$DATA/server/private.key"
    wg pubkey < "$DATA/server/private.key" > "$DATA/server/public.key"
  fi
}

next_free_ip() {
  local i n used
  used=" $(cat "$DATA"/clients/*/ip 2>/dev/null | tr '\n' ' ') "
  for i in $(seq 2 254); do
    n="$WG_SUBNET_PREFIX.$i"
    [[ "$used" == *" $n "* ]] || { echo "$n"; return; }
  done
  die "no free addresses left in $WG_SUBNET"
}

render_server_conf() {
  local name dir
  mkdir -p /etc/wireguard
  {
    cat <<EOF
[Interface]
Address = $WG_SUBNET_PREFIX.1/24
ListenPort = $LISTEN_PORT
PrivateKey = $(cat "$DATA/server/private.key")
PostUp = iptables -t nat -A POSTROUTING -s $WG_SUBNET ! -o %i -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s $WG_SUBNET ! -o %i -j MASQUERADE
EOF
    for name in $(client_names); do
      dir=$(client_dir "$name")
      cat <<EOF

# $name
[Peer]
PublicKey = $(cat "$dir/public.key")
PresharedKey = $(cat "$dir/psk")
AllowedIPs = $(cat "$dir/ip")/32
EOF
    done
  } > "$WG_CONF"
}

# $1 = name, $2 = full|lan
render_client_profile() {
  local name=$1 kind=$2 dir allowed out
  dir=$(client_dir "$name")
  case "$kind" in
    full) allowed="0.0.0.0/0, ::/0" ;;
    lan)  allowed="$WG_SUBNET, $(echo "$WG_LAN_ROUTES" | sed 's/[ ,]\+/, /g')" ;;
  esac
  out="$dir/$name-$kind.conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $(cat "$dir/private.key")"
    echo "Address = $(cat "$dir/ip")/32"
    [[ -n "$WG_DNS" ]] && echo "DNS = $WG_DNS"
    cat <<EOF

[Peer]
PublicKey = $(cat "$DATA/server/public.key")
PresharedKey = $(cat "$dir/psk")
Endpoint = $WG_HOST:$WG_PORT
AllowedIPs = $allowed
PersistentKeepalive = 25
EOF
  } > "$out"
  qrencode -t png -o "$dir/$name-$kind.png" < "$out"
}

render_client_profiles() {
  local name
  for name in $(client_names); do
    render_client_profile "$name" full
    render_client_profile "$name" lan
  done
}

# Apply peer changes to the running interface without dropping sessions.
sync_running_interface() {
  wg show wg0 >/dev/null 2>&1 || return 0
  wg syncconf wg0 <(wg-quick strip wg0)
}
