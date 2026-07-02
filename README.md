# VLESS+REALITY -> WireGuard Tunnel

Tunnel traffic over **VLESS+REALITY** (a genuine TLS 1.3 connection on
port 443 that mimics a real website) to a public-IP **VPS**, which relays it over
**WireGuard** to your **home server**, which is the **Internet exit**. The public-facing
source IP is your **residential home IP**.

This is helpful for bypassing UDP blocks on Public Wi-Fi, it disguises all traffic as real HTTPS and dials to your VPS on port 443, 
with TLS handshakes relayed from a real domain (e.g. `dl.google.com`) to defeat DPI and active probing.

```
 Phone (sing-box, TUN)  --VLESS+REALITY/TCP 443-->  VPS (public IP)  --WireGuard-->  Home server  -->  Internet
        all traffic        looks like HTTPS to        relay only                      NAT exit        residential IP
                           dl.google.com
```

The VPS only relays — it never exits to the Internet itself. sing-box on the VPS
terminates VLESS+REALITY **and** runs a userspace WireGuard endpoint, so the VPS needs a
single container with no privileged kernel access.

## Why VLESS+REALITY

The censored leg carries **no UDP on the wire** (it's a single TCP/TLS stream — app UDP
like QUIC/DNS is multiplexed inside it) and is **indistinguishable from a real browser
hitting `dl.google.com`**: REALITY relays the genuine TLS handshake of that domain,
so the certificate is authentic and active probing just hits the real site. This defeats
both UDP-targeted censorship and DPI/TLS-fingerprinting.

## Layout

```
.env.example                      # copy to .env, fill in all secrets
render.sh                         # envsubst .env into the configs below
vps/                              # public-IP relay
  docker-compose.yml
  sing-box/config.json.tmpl       # VLESS+REALITY inbound + WireGuard endpoint (routes all to home)
home-server/                      # residential exit (no public IP)
  docker-compose.yml              # kernel WireGuard (linuxserver), joins AdGuard's bridge
  wireguard/wg_confs/wg0.conf.tmpl  # dials OUT to VPS, NAT-masquerades to WAN
client/
  sing-box-phone.json.tmpl        # Android sing-box profile (VLESS+REALITY, DNS via AdGuard)
```

## The one constraint that shapes everything

The home server has **no public IP**, so it must *initiate* the WireGuard handshake
outbound. Therefore:

- The **VPS** is the WireGuard **listener** (`listen_port 51820`) with **no** `Endpoint`
  for its peer — it learns the home's address from the first handshake (roaming peer).
- The **home server** has `Endpoint = <VPS_IP>:51820` and `PersistentKeepalive = 25` to
  keep its NAT pinhole open so the VPS can push client + return traffic back down the tunnel.

A boot test of the VPS shows `failed to send handshake initiation: no known endpoint
for peer` until the home server connects — **this is expected and correct.**

## Credentials / config files

No secrets are committed. Configs are `.tmpl` files with `${VAR}` placeholders; you
put all secrets in **one `.env`** at the repo root, and `./render.sh` generates the
real files. Both `.env` and the rendered files are gitignored.

```bash
./gen-secrets.sh            # generates all keys/UUID into .env (only VPS_IP left blank)
# edit .env -> set VPS_IP
./render.sh                 # renders all three configs from the templates
```

`gen-secrets.sh` auto-generates every secret (REALITY keypair, UUID, short_id, both
WireGuard keypairs) using local `sing-box`/`wg` or Docker, and preserves an existing
`VPS_IP`. Re-run it to **rotate** all keys (your previous `.env` is backed up first).
Only `VPS_IP` is filled in by hand.

`render.sh` fails loudly if any `.env` value is empty or any placeholder is left
unsubstituted, so a half-filled `.env` can't produce a broken config.

`.env` holds these (one place — each is reused across files automatically):

| Variable | Used in |
|----------|---------|
| `VPS_IP` | `wg0.conf` (`Endpoint`), `sing-box-phone.json` (`server`) |
| `VLESS_UUID` | `config.json`, `sing-box-phone.json` |
| `REALITY_PRIVATE_KEY` | `config.json` (`reality.private_key`) |
| `REALITY_PUBLIC_KEY` | `sing-box-phone.json` (`reality.public_key`) — pair of the private key |
| `REALITY_SHORT_ID` | both configs |
| `VPS_WG_PRIVATE_KEY` | `config.json` (`private_key`) |
| `VPS_WG_PUBLIC_KEY` | `wg0.conf` (`[Peer] PublicKey`) |
| `HOME_WG_PRIVATE_KEY` | `wg0.conf` (`[Interface] PrivateKey`) |
| `HOME_WG_PUBLIC_KEY` | `config.json` (peer `public_key`) |

Re-run `./render.sh` any time you rotate a key. Handshake / SNI is `dl.google.com`;
tunnel addresses are VPS `10.10.0.1`, home `10.10.0.2`.

## You must adapt to your environment

1. **`VPS_IP`** — set your VPS public IP once in `.env`; `render.sh` writes it into
   `wg0.conf` (`Endpoint`) and `sing-box-phone.json` (`server`).
2. **AdGuard Home** — the phone resolves DNS via AdGuard at `172.30.0.53:53` over the
   tunnel. This requires AdGuard pinned to that IP on a shared `adguardhome` Docker bridge
   that the WireGuard container also joins (see DNS section below). If you don't run
   AdGuard, point the client DNS `server` at any resolver and keep `detour: proxy`.

## Deploy

### 1. VPS (public IP)

```bash
./render.sh                 # if not already done — generates vps/sing-box/config.json
cd vps
docker compose up -d
docker compose logs -f      # VLESS started on :443, WG listening on :51820
```

Open firewall: TCP `443`, UDP `51820`.

### 2. Home server (no public IP)

The WireGuard container joins AdGuard's external `adguardhome` bridge, so that network
must exist first (created by the AdGuard compose project — see DNS section).

```bash
cd home-server
# wireguard/wg_confs/wg0.conf is produced by ../render.sh from .env
docker compose up -d
docker compose exec wireguard wg        # check: latest handshake + transfer counters
```

A healthy `wg` shows a recent handshake with the VPS peer and **both** rx and tx growing.
(If `received` climbs but `sent` stays near zero, the home NAT/masquerade is broken.)

### 3. Phone (Android, sing-box app)

1. Install **sing-box** (1.13.x core) from Play Store / GitHub releases.
2. `client/sing-box-phone.json` is produced by `render.sh` (VPS IP comes from `.env`).
3. Import the profile (paste JSON, or host it and import by URL).
4. Start the VPN. Verify exit IP — it should match your **home** residential IP:
   ```
   open https://ifconfig.me
   ```

## How traffic flows

| Leg | Transport | Why |
|-----|-----------|-----|
| Phone → VPS | **VLESS+REALITY** over TCP 443; app UDP multiplexed inside the TLS stream | Censored leg looks like real HTTPS to `dl.google.com`; no UDP on the wire; survives DPI + active probing. |
| VPS → Home | **WireGuard** (UDP) | Clean network between datacenter and home; WireGuard is fast and simple here. |
| Home → Internet | NAT masquerade out residential WAN | Exit point — your public IP is your home IP. |

## DNS / adblocking (AdGuard Home)

The phone's DNS is hijacked (`hijack-dns` route action) and sent to AdGuard Home at
**`172.30.0.53:53`** *through the tunnel* (`detour: proxy`), so queries are filtered for
ads and never leak in plaintext on the censored leg.

Reaching AdGuard required solving a NAT/firewall issue: a container sending to the host's
`:53` is an INPUT packet that the host firewall silently drops. The fix is a **shared
Docker bridge**:

- AdGuard's compose defines a bridge `adguardhome` (`subnet 172.30.0.0/24`) and pins
  AdGuard to `172.30.0.53`.
- The WireGuard container joins that same external bridge (`home-server/docker-compose.yml`).
- Phone DNS then reaches `172.30.0.53` **container-to-container**, bypassing the host
  INPUT chain entirely.

In AdGuard → Settings → DNS settings, ensure **Listen interfaces** = All, and **Access
settings → Allowed clients** is empty (or includes `172.30.0.0/24`), or queries are
silently dropped.

> [!NOTE]
> You need to setup Adguard Home separately (not included in this repo) and ensure it's running on the same Docker host as the home WireGuard container, with the shared `adguardhome` bridge as described above.

## Verification done in this repo

Both sing-box configs were validated against `sing-box v1.13.13` (`check`), both compose
files against `docker compose config`, the VPS config was boot-tested in a real container
(VLESS started on `:443`, REALITY initialized, WireGuard listener up), and the chosen
REALITY handshake domain was confirmed to support TLS 1.3 + HTTP/2.

## Generating credentials

Just run `./gen-secrets.sh` — it generates everything into `.env` for you, then
`./render.sh` writes the configs with the values correctly paired across files.

The pairing it handles automatically: the REALITY **private** key goes on the VPS, its
**public** key on the phone; the same **UUID** and **short_id** appear on both ends; VPS
WG private ↔ home WG public, and home WG private ↔ VPS WG public, stay paired.

Under the hood it runs (via local `sing-box`/`wg` or Docker):

```bash
sing-box generate reality-keypair   # REALITY private/public pair
sing-box generate uuid              # VLESS UUID
sing-box generate rand 8 --hex      # REALITY short_id
wg genkey | tee priv | wg pubkey    # WireGuard keypair (run for VPS and home)
```
