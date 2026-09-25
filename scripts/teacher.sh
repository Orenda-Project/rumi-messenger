#!/usr/bin/env bash
# teacher.sh add "<phone like +923001234567>" "<Full Name>" [--password X]
#
# Onboards one teacher for user-directory discoverability (issue #10, "let teachers find each
# other"): creates the account (or leaves an existing one alone), sets a real display name so
# Element X's start-chat search shows a name instead of a bare phone number, and joins them to
# #rumi-announcements so they land in the same place a self-registered teacher would via
# auto_join_rooms (scripts/setup.sh). Idempotent: re-running with the same phone updates the
# display name and (re-)confirms room membership, never fails or resets the password.
#
# Username convention matches docs/RUNBOOK.md / scripts/devices.sh: the phone number WITH its
# leading "+", used verbatim as the Matrix localpart (e.g. +923001234567 -> @+923001234567:<server>).
# bash + curl + python3 only, admin-token pattern lifted straight from scripts/devices.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; DEPLOY="$HERE/../deploy"
# RUMI_ENV_FILE=deploy/railway/.env.railway (or any deployment's settings file carrying
# SYNAPSE_URL, SERVER_NAME, ADMIN_USER, ADMIN_PASSWORD) targets that server over its public URL.
# shellcheck disable=SC1090
source "${RUMI_ENV_FILE:-$DEPLOY/.env}"
HS="${SYNAPSE_URL:-http://${BIND_ADDR:-127.0.0.1}:${SYNAPSE_PORT:-8008}}"
SERVER_NAME="${SERVER_NAME:-localhost}"
ANNOUNCE_ALIAS="%23rumi-announcements:${SERVER_NAME}"

usage() { sed -n '2,3p' "$0"; exit 64; }

cmd="${1:-}"; [ "$cmd" = "add" ] || usage
phone="${2:-}"; name="${3:-}"
[ -n "$phone" ] && [ -n "$name" ] || usage
password=""
shift 3 2>/dev/null || shift $#
while [ $# -gt 0 ]; do
  case "$1" in
    --password) password="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

case "$phone" in
  +*) : ;;
  *) echo "phone must start with + (e.g. +923001234567), got: $phone" >&2; exit 64 ;;
esac

mxid="@${phone}:${SERVER_NAME}"
enc_mxid="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$mxid")"

tok="$(curl -sS -X POST "$HS/_matrix/client/v3/login" -H 'Content-Type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${ADMIN_USER}\"},\"password\":\"${ADMIN_PASSWORD}\"}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')"
[ -n "$tok" ] || { echo "ERROR: could not log in as admin (${ADMIN_USER})" >&2; exit 1; }

# Does the account already exist? GET returns 404 if not, 200 (with a body) if it does.
exists_http="$(curl -sS -o /tmp/teacher-sh-get.json -w '%{http_code}' \
  -H "Authorization: Bearer $tok" "$HS/_synapse/admin/v2/users/${enc_mxid}")"

if [ "$exists_http" = "200" ]; then
  echo "account $mxid already exists -- updating display name only, password untouched"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    "$HS/_synapse/admin/v2/users/${enc_mxid}" \
    -d "$(python3 -c 'import json,sys;print(json.dumps({"displayname": sys.argv[1]}))' "$name")")"
  [ "$code" = "200" ] || { echo "ERROR: displayname update failed, HTTP $code" >&2; exit 1; }
else
  if [ -z "$password" ]; then
    password="$(openssl rand -hex 12)"
    echo "no --password given, generated one: $password (shown once -- save it)"
  fi
  echo "creating $mxid"
  body="$(python3 -c 'import json,sys;print(json.dumps({"password": sys.argv[1], "displayname": sys.argv[2], "admin": False}))' "$password" "$name")"
  code="$(curl -sS -o /tmp/teacher-sh-put.json -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    "$HS/_synapse/admin/v2/users/${enc_mxid}" -d "$body")"
  # Synapse returns 201 Created on first creation via this endpoint, 200 OK on modify -- both are
  # success (verified live).
  case "$code" in
    200|201) : ;;
    *) echo "ERROR: account creation failed, HTTP $code: $(cat /tmp/teacher-sh-put.json)" >&2; exit 1 ;;
  esac
fi

# Join #rumi-announcements via the admin Edit Room Membership API (POST /_synapse/admin/v1/join/
# <room_id_or_alias>) -- an admin-created account never goes through the registration flow that
# auto_join_rooms hooks into (scripts/setup.sh), so this is the explicit equivalent for teachers
# onboarded this way. Safe to repeat: joining a room you're already in is a no-op.
join_code="$(curl -sS -o /tmp/teacher-sh-join.json -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
  "$HS/_synapse/admin/v1/join/${ANNOUNCE_ALIAS}" \
  -d "$(python3 -c 'import json,sys;print(json.dumps({"user_id": sys.argv[1]}))' "$mxid")")"
if [ "$join_code" = "200" ]; then
  echo "$mxid joined #rumi-announcements"
else
  echo "WARNING: could not join $mxid to #rumi-announcements, HTTP $join_code: $(cat /tmp/teacher-sh-join.json)" >&2
fi

echo "done: $mxid (\"$name\")"
