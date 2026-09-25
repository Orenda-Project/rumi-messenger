#!/usr/bin/env bash
# bot-cross-sign.sh [--user @x:server --device ID --recovery-key-file PATH]   (password via XSIGN_PASSWORD)
#
# Removes the red "encrypted by a device not verified by its owner" shield from Rumi's replies
# (rumi-messenger#15). The bot (matrix-bot-sdk 0.8.0) cannot bootstrap cross-signing itself, so this
# does it OUT-OF-BAND: a temporary matrix-js-sdk device logs in as @rumi, creates cross-signing keys,
# signs the bot's EXISTING device with the self-signing key, keeps the private keys in secret
# storage under a recovery key, and logs itself out. The bot process, its access token, its device
# and its .matrix-storage are never touched -- no restart needed.
#
# Defaults (no args): user @rumi:<SERVER_NAME>, password RUMI_BOT_PASSWORD from deploy/.env, device
# = whatever device the token in deploy/rumi-channel.env belongs to, recovery key file
# deploy/rumi-cross-signing-recovery-key.txt (chmod 600, gitignored -- BACK IT UP; losing it means
# the next new bot device can only be signed after an identity reset).
#
# Idempotent: re-running when the device is already signed is a no-op. If the bot ever gets a new
# device (new token), re-run: it reloads the keys from secret storage with the recovery key and signs
# the new device. It refuses, rather than resets, if keys exist and the recovery key file is missing.
# Needs Node >= 22 (uses ~/.nvm node 24.4.1 if present); installs matrix-js-sdk into
# scripts/bot-cross-sign/node_modules on first run (gitignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; DEPLOY="$HERE/../deploy"; TOOL="$HERE/bot-cross-sign"
# RUMI_ENV_FILE / SYNAPSE_URL / RUMI_CHANNEL_ENV point it at another deployment (Railway:
# scripts/railway-bootstrap.sh --cross-sign sets all three). Defaults = the compose stack.
# shellcheck disable=SC1090
source "${RUMI_ENV_FILE:-$DEPLOY/.env}"
HS="${SYNAPSE_URL:-http://${BIND_ADDR:-127.0.0.1}:${SYNAPSE_PORT:-8008}}"
CHANNEL_ENV="${RUMI_CHANNEL_ENV:-$DEPLOY/rumi-channel.env}"
NODE="$HOME/.nvm/versions/node/v24.4.1/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node)"
NPM="$(dirname "$NODE")/npm"; [ -x "$NPM" ] || NPM="$(command -v npm)"

user="@rumi:${SERVER_NAME}"; device=""; keyfile="$DEPLOY/rumi-cross-signing-recovery-key.txt"
while [ $# -gt 0 ]; do
  case "$1" in
    --user) user="$2"; shift 2 ;;
    --device) device="$2"; shift 2 ;;
    --recovery-key-file) keyfile="$2"; shift 2 ;;
    *) sed -n '2p' "$0"; exit 64 ;;
  esac
done
if [ "$user" = "@rumi:${SERVER_NAME}" ]; then
  export XSIGN_PASSWORD="${XSIGN_PASSWORD:-$RUMI_BOT_PASSWORD}"
  if [ -z "$device" ]; then
    tok="$(sed -n 's/^MATRIX_ACCESS_TOKEN=//p' "$CHANNEL_ENV")"
    device="$(curl -sS -H "Authorization: Bearer $tok" "$HS/_matrix/client/v3/account/whoami" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["device_id"])')"
    unset tok
  fi
fi
[ -n "${XSIGN_PASSWORD:-}" ] && [ -n "$device" ] || { echo "need XSIGN_PASSWORD and --device for a non-rumi user" >&2; exit 64; }
[ -d "$TOOL/node_modules/matrix-js-sdk" ] || (cd "$TOOL" && "$NPM" ci --silent --no-audit --no-fund)
echo "cross-signing $user, bot device $device, recovery key file $keyfile"
exec "$NODE" "$TOOL/bot-cross-sign.mjs" --hs "$HS" --user "$user" --device "$device" --recovery-key-file "$keyfile"
