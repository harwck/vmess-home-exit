#!/bin/bash
# linuxserver custom init hook (runs as root at container start, every start).
# Installs the tunnel-watchdog cron line into busybox crond's root crontab.
#
# Why a custom-init script instead of /config/crontabs/root:
#   This image's init-crontab-config only imports /config/crontabs/<user> when a
#   matching /defaults/crontabs/<user> exists — and this image ships none, so a
#   dropped-in crontab file is silently ignored. busybox crond actually reads
#   /var/spool/cron/crontabs/root (managed via `crontab`), which this hook edits
#   directly. Verified against lscr.io/linuxserver/wireguard:1.0.20250521.

set -eu

CRON_LINE='* * * * * /bin/bash /config/wg-watchdog.sh'
MARKER='/config/wg-watchdog.sh'

# Current root crontab (busybox: `crontab -l`), minus any prior watchdog line, plus ours.
current="$(crontab -l 2>/dev/null || true)"
filtered="$(printf '%s\n' "$current" | grep -vF "$MARKER" || true)"
printf '%s\n%s\n' "$filtered" "$CRON_LINE" | sed '/^$/d' | crontab -

echo "[wg-watchdog] installed cron line: ${CRON_LINE}"
