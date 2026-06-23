#!/usr/bin/env bash
# Tunnel watchdog — runs INSIDE the ss-tunnel-home container (mounted at
# /config/wg-watchdog.sh, invoked by cron via /config/crontabs/root).
#
# Why this exists:
#   The home server is a ROAMING WireGuard peer — the VPS has no configured
#   Endpoint for it and learns home's address only from packets it can decrypt.
#   When the VPS restarts it loses both its session keys AND its memory of where
#   home is. Home keeps sending keepalives encrypted with the now-dead session,
#   which the VPS silently drops ("no known endpoint for peer"), so the VPS can
#   never re-learn home on its own. Only HOME can break the deadlock by sending a
#   fresh handshake initiation — and the reliable way to force that is to bounce
#   the interface (which also re-applies the PostUp NAT rules).
#
# This pings the VPS's tunnel IP; on sustained failure it bounces wg0. A healthy
# tunnel is left untouched, so there are no periodic handshake blips.

set -u

PEER_TUNNEL_IP="10.10.0.1"   # VPS end of the tunnel (static, from config.json endpoints[0].address)
IFACE="wg0"
ATTEMPTS=3                   # consecutive ping rounds that must all fail before acting
PING_COUNT=3                 # echo requests per round
PING_TIMEOUT=5               # seconds per round

log() { logger -t wg-watchdog "$*" 2>/dev/null || echo "wg-watchdog: $*"; }

for i in $(seq 1 "$ATTEMPTS"); do
  if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PEER_TUNNEL_IP" >/dev/null 2>&1; then
    exit 0   # tunnel healthy — nothing to do
  fi
  sleep 2
done

log "VPS tunnel ${PEER_TUNNEL_IP} unreachable after ${ATTEMPTS} rounds — bouncing ${IFACE}"
if wg-quick down "$IFACE" 2>&1 | logger -t wg-watchdog; then :; fi
if wg-quick up "$IFACE" 2>&1 | logger -t wg-watchdog; then :; fi
log "bounce complete"
