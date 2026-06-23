#!/usr/bin/env bash
# Render real config files from *.tmpl using values in .env.
# Usage: ./render.sh
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "ERROR: .env not found. Copy .env.example to .env and fill it in." >&2; exit 1; }

# Load .env into the environment.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# Every variable the templates reference. Kept explicit so envsubst only
# substitutes these (a bare `envsubst` would eat any other $… in the files).
VARS=(VPS_IP VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID SS_PASSWORD \
      VPS_WG_PRIVATE_KEY VPS_WG_PUBLIC_KEY HOME_WG_PRIVATE_KEY HOME_WG_PUBLIC_KEY)

# Fail loudly if any required value is empty.
missing=()
for v in "${VARS[@]}"; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: these .env values are empty: ${missing[*]}" >&2
  exit 1
fi

# Build the "${VAR}" allowlist string envsubst expects.
subst=""
for v in "${VARS[@]}"; do subst+="\${$v}"; done

render() {
  local tmpl="$1" out="${1%.tmpl}"
  envsubst "$subst" < "$tmpl" > "$out"
  # Guard against any leftover unsubstituted placeholder.
  if grep -q '\${' "$out"; then
    echo "ERROR: $out still has unsubstituted placeholders:" >&2
    grep -n '\${' "$out" >&2
    exit 1
  fi
  echo "rendered $out"
}

render vps/sing-box/config.json.tmpl
render home-server/wireguard/wg_confs/wg0.conf.tmpl
render client/sing-box-phone.json.tmpl

echo "Done. Real configs written (gitignored)."
