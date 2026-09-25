#!/usr/bin/env bash
# railway-bootstrap.sh -- one-time accounts + rooms for a Rumi Messenger on Railway (docs/RAILWAY.md).
#
# Run from YOUR laptop against the public server, after the Railway services are up. It does what
# scripts/setup.sh steps 7-8 do on the compose stack, but over the public API (no `docker exec`):
# creates the admin and @rumi accounts through Synapse's shared-secret registrar, sets Rumi's name
# and avatar, makes sure "Rumi Announcements" exists and is named, and writes the bot credentials
# rumi-platform needs to deploy/railway/rumi-channel.env (chmod 600, gitignored). Idempotent.
#
# Settings come from deploy/railway/.env.railway (RUMI_ENV_FILE to use another file), which
# scripts/railway-deploy.sh writes: SYNAPSE_URL, SERVER_NAME, REG_SHARED_SECRET, ADMIN_USER,
# ADMIN_PASSWORD, RUMI_BOT_PASSWORD. Re-run with `--cross-sign` AFTER rumi-platform has started
# once with the new token (the bot's device keys only exist on the server from then on): it runs
# scripts/bot-cross-sign.sh against this server (Node >= 22; writes
# deploy/railway/rumi-cross-signing-recovery-key.txt -- back it up).
# Needs bash, curl, python3, openssl.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
ENV_FILE="${RUMI_ENV_FILE:-$ROOT/deploy/railway/.env.railway}"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE -- run scripts/railway-deploy.sh first (or set RUMI_ENV_FILE)" >&2; exit 1; }
set -a; # shellcheck disable=SC1090
source "$ENV_FILE"; set +a
: "${SYNAPSE_URL:?}" "${SERVER_NAME:?}" "${REG_SHARED_SECRET:?}" "${ADMIN_PASSWORD:?}" "${RUMI_BOT_PASSWORD:?}"
ADMIN_USER="${ADMIN_USER:-admin}"
HS="${SYNAPSE_URL%/}"
OUT_DIR="$(dirname "$ENV_FILE")"
CHANNEL_ENV="${RUMI_CHANNEL_ENV:-$OUT_DIR/rumi-channel.env}"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
jget() { python3 -c 'import json,sys
try: d=json.loads(sys.argv[1])
except Exception: d={}
v=d.get(sys.argv[2]) if isinstance(d,dict) else None
print("" if v is None else v)' "$1" "$2"; }

log "waiting for $HS"
for i in $(seq 1 60); do
  curl -fsS "$HS/_matrix/client/versions" >/dev/null 2>&1 && break
  [ "$i" = 60 ] && { echo "Synapse not reachable at $HS" >&2; exit 1; }
  sleep 5
done

# Synapse shared-secret registration (same HMAC handshake scripts/e2e.sh uses).
register() { # user password admin|notadmin
  local nonce mac body resp
  nonce="$(jget "$(curl -fsS "$HS/_synapse/admin/v1/register")" nonce)"
  mac="$(python3 -c 'import hashlib,hmac,sys
n,u,p,a,s=sys.argv[1:6]
print(hmac.new(s.encode(), b"\x00".join([n.encode(),u.encode(),p.encode(),a.encode()]), hashlib.sha1).hexdigest())' \
    "$nonce" "$1" "$2" "$3" "$REG_SHARED_SECRET")"
  body="$(python3 -c 'import json,sys; n,u,p,a,m=sys.argv[1:6]; print(json.dumps({"nonce":n,"username":u,"password":p,"admin":a=="admin","mac":m}))' "$nonce" "$1" "$2" "$3" "$mac")"
  resp="$(curl -sS -X POST "$HS/_synapse/admin/v1/register" -H 'Content-Type: application/json' -d "$body")"
  case "$(jget "$resp" errcode)" in
    "") log "created @$1:$SERVER_NAME" ;;
    M_USER_IN_USE) log "@$1:$SERVER_NAME already exists" ;;
    *) echo "ERROR registering $1: $resp" >&2; exit 1 ;;
  esac
}
login() { # user password -> access token (retries on 429 like setup.sh)
  local out code
  for _ in 1 2 3 4 5; do
    out="$(curl -sS -w '\n%{http_code}' -X POST "$HS/_matrix/client/v3/login" -H 'Content-Type: application/json' \
      -d "$(python3 -c 'import json,sys;print(json.dumps({"type":"m.login.password","identifier":{"type":"m.id.user","user":sys.argv[1]},"password":sys.argv[2],"initial_device_display_name":sys.argv[3]}))' "$1" "$2" "${3:-railway-bootstrap}")")"
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    [ "$code" = 200 ] && { jget "$out" access_token; return; }
    [ "$code" = 429 ] && { sleep 6; continue; }
    echo "ERROR: login $1 HTTP $code: $out" >&2; return 1
  done
  echo "ERROR: login $1 still rate-limited" >&2; return 1
}

# Admin FIRST: Synapse autocreates #rumi-announcements (auto_join_rooms) as the first user, and
# the room's creator is the one member sure to hold the power to name it (setup.sh relies on this too).
register "$ADMIN_USER" "$ADMIN_PASSWORD" admin
register rumi "$RUMI_BOT_PASSWORD" notadmin

BOT_ID="@rumi:$SERVER_NAME"
BOT_TOKEN=""
if [ -f "$CHANNEL_ENV" ]; then
  BOT_TOKEN="$(sed -n 's/^MATRIX_ACCESS_TOKEN=//p' "$CHANNEL_ENV")"
  if [ -n "$BOT_TOKEN" ] && curl -fsS -H "Authorization: Bearer $BOT_TOKEN" "$HS/_matrix/client/v3/account/whoami" >/dev/null 2>&1; then
    log "existing @rumi token in $CHANNEL_ENV still valid, reusing it"
  else BOT_TOKEN=""; fi
fi
[ -n "$BOT_TOKEN" ] || BOT_TOKEN="$(login rumi "$RUMI_BOT_PASSWORD" "rumi-platform")"
umask 077
cat > "$CHANNEL_ENV" <<EOF
# Written by scripts/railway-bootstrap.sh. rumi-platform reads this to log @rumi into Matrix
# (RUMI_CHANNEL_ENV=<this file> scripts/connect-rumi.sh /path/to/rumi-platform).
MATRIX_HOMESERVER_URL=$HS
MATRIX_ACCESS_TOKEN=$BOT_TOKEN
MATRIX_USER_ID=$BOT_ID
EOF
chmod 600 "$CHANNEL_ENV"
log "wrote $CHANNEL_ENV (chmod 600)"

AUTH=(-H "Authorization: Bearer $BOT_TOKEN" -H 'Content-Type: application/json')
ENC_BOT="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$BOT_ID")"
curl -fsS -X PUT "$HS/_matrix/client/v3/profile/$ENC_BOT/displayname" "${AUTH[@]}" -d '{"displayname":"Rumi"}' >/dev/null
if [ -z "$(jget "$(curl -sS "$HS/_matrix/client/v3/profile/$ENC_BOT/avatar_url")" avatar_url)" ]; then
  MXC="$(jget "$(curl -fsS -X POST "$HS/_matrix/media/v3/upload?filename=rumi-avatar.png" -H "Authorization: Bearer $BOT_TOKEN" \
    -H 'Content-Type: image/png' --data-binary @"$ROOT/deploy/element/assets/rumi-avatar-navy.png")" content_uri)"
  curl -fsS -X PUT "$HS/_matrix/client/v3/profile/$ENC_BOT/avatar_url" "${AUTH[@]}" -d "{\"avatar_url\":\"$MXC\"}" >/dev/null
  log "Rumi avatar set ($MXC)"
else
  log "Rumi avatar already set"
fi

ALIAS="%23rumi-announcements:$SERVER_NAME"
ROOM_ID="$(jget "$(curl -sS "$HS/_matrix/client/v3/directory/room/$ALIAS" "${AUTH[@]}")" room_id)"
if [ -z "$ROOM_ID" ]; then
  ROOM_ID="$(jget "$(curl -fsS -X POST "$HS/_matrix/client/v3/createRoom" "${AUTH[@]}" \
    -d '{"room_alias_name":"rumi-announcements","name":"Rumi Announcements","topic":"Updates from Rumi and your team","visibility":"public","preset":"public_chat"}')" room_id)"
  log "created #rumi-announcements ($ROOM_ID)"
fi
if [ "$(jget "$(curl -sS "$HS/_matrix/client/v3/rooms/$ROOM_ID/state/m.room.name" "${AUTH[@]}")" name)" != "Rumi Announcements" ]; then
  ADMIN_TOKEN="$(login "$ADMIN_USER" "$ADMIN_PASSWORD")"
  curl -fsS -X PUT "$HS/_matrix/client/v3/rooms/$ROOM_ID/state/m.room.name" -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H 'Content-Type: application/json' -d '{"name":"Rumi Announcements"}' >/dev/null
  curl -sS -X POST "$HS/_matrix/client/v3/logout" -H "Authorization: Bearer $ADMIN_TOKEN" >/dev/null || true
  log "named #rumi-announcements \"Rumi Announcements\""
else
  log "#rumi-announcements already named"
fi
# The bot must be IN the welcome room to see teachers join it (that is what triggers the greeting).
curl -sS -X POST "$HS/_matrix/client/v3/join/$ALIAS" "${AUTH[@]}" -d '{}' >/dev/null

if [ "${1:-}" = "--cross-sign" ]; then
  log "cross-signing the bot device (scripts/bot-cross-sign.sh)"
  RUMI_ENV_FILE="$ENV_FILE" RUMI_CHANNEL_ENV="$CHANNEL_ENV" SYNAPSE_URL="$HS" \
    "$HERE/bot-cross-sign.sh" --recovery-key-file "$OUT_DIR/rumi-cross-signing-recovery-key.txt"
fi

echo
echo "Done. Server:  $HS   (server name $SERVER_NAME)"
echo "      Admin:   $ADMIN_USER (password in $ENV_FILE)"
echo "      Bot:     $BOT_ID -> $CHANNEL_ENV"
echo "Next: RUMI_ENV_FILE=$ENV_FILE scripts/teacher.sh add \"+923001234567\" \"Teacher Name\""
[ "${1:-}" = "--cross-sign" ] || echo "Then: connect Rumi (docs/RAILWAY.md step 6), start it once, and re-run: scripts/railway-bootstrap.sh --cross-sign"
