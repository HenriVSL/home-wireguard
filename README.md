# home-wireguard

A small WireGuard VPN server in a container, built to be left alone.

- Every device gets **two profiles**:
  - `<name>-full`: all traffic goes through home
  - `<name>-lan`: only home LAN traffic goes through the VPN (`192.168.1.0/24`)
- Clients use `192.168.1.201` for DNS.
- Manage devices from a small web page on the home network (password
  protected), or from the command line on the server.

## How it stays up to date

```
GitHub Actions (Mondays)            Server (Tuesdays, cron)
  build from fresh alpine:3           update.sh
  real-tunnel end-to-end test   ──►     pull :latest
  publish only if tests pass            restart container, wait for healthy
  failure → email to you                unhealthy → roll back to previous image
```

- The WireGuard encryption runs in the host kernel, which Ubuntu updates.
  The container only holds the configuration tools.
- Keys and clients live in `./data`. Every update rebuilds everything else.
- Each test run also checks the upgrade path. It creates a client with the
  currently published image, then starts the new image on the same data,
  and the old profile must still connect.
- **If GitHub emails you that a run failed**, nothing reaches the server.
  The VPN keeps running the last good image until you look at it.

## Usage

**Web page:** open `http://<server-ip>:8088` from any device at home (or
while connected to the VPN) and log in with `WEB_PASSWORD` from `.env`.
Add a device, then scan its QR code with the WireGuard app or download the
`.conf` on the device itself.

**Command line** (on the server, from any folder):

```bash
vpn add phone           # creates phone-full + phone-lan
vpn show phone          # QR codes in the terminal (scan with the WireGuard app)
vpn show phone lan      # just one profile
vpn export phone        # .conf + .png files to ~/vpn-profiles
vpn list                # clients + last handshake
vpn remove phone
vpn backup              # tar of all keys -> keep a copy elsewhere
vpn logs                # container log + update log
vpn update              # update now instead of waiting for Tuesday
```

## Setup

```bash
git clone https://github.com/HenriVSL/home-wireguard ~/home-wireguard
cd ~/home-wireguard
cp .env.example .env      # check the values
docker compose up -d
ln -sf ~/home-wireguard/vpn ~/.local/bin/vpn
(crontab -l 2>/dev/null; echo "30 4 * * 2 $HOME/home-wireguard/update.sh >> $HOME/home-wireguard/update.log 2>&1") | crontab -
```

On the router, forward UDP `51820` to this machine. Do **not** forward the
web page port. The host must have the
`wireguard` kernel module (built into Ubuntu kernels 5.6+).

## Configuration (`.env`)

| Variable | Meaning |
|---|---|
| `WG_HOST` / `WG_PORT` | Public address and UDP port written into the profiles |
| `WG_DNS` | DNS server for clients |
| `WG_LAN_ROUTES` | Networks the `lan` profile sends through the VPN |
| `WG_SUBNET_PREFIX` | VPN addresses (`10.66.66.x`) |
| `WEB_PASSWORD` / `WEB_PORT` | Web page login and port; empty password turns the page off |

Every container start regenerates the profiles from `.env`. If you change
DNS or routes, run `docker compose up -d` and re-import the profiles on
your devices. Keys stay the same.

## Testing locally

```bash
docker build -t home-wireguard:test . && tests/e2e.sh home-wireguard:test
```
