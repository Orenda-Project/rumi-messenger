#!/usr/bin/env bash
# Rumi Messenger -- end-to-end verification. Exits non-zero if any check fails.
# Prints one clean PASS/FAIL line per check (never a Python traceback, even if Synapse/Element
# are down) and moves on. Requires: bash, curl, python3. Run scripts/setup.sh first.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "FAIL: ${ENV_FILE} not found -- run scripts/setup.sh first"
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

SERVER_NAME="${SERVER_NAME:-localhost}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
SYNAPSE_PORT="${SYNAPSE_PORT:-8008}"
ELEMENT_PORT="${ELEMENT_PORT:-8082}"
SYNAPSE_URL="http://${BIND_ADDR}:${SYNAPSE_PORT}"
ELEMENT_URL="http://${BIND_ADDR}:${ELEMENT_PORT}"

PASS_COUNT=0
FAIL_COUNT=0
CLEANUP_USERS=()

check() {
  local desc="$1" ok="$2" detail="${3:-}"
  if [[ "${ok}" == "1" ]]; then
    echo "PASS: ${desc}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: ${desc} (${detail:-no reason given})"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ---------------------------------------------------------------------------
# JSON helpers: NEVER raise/traceback, regardless of malformed/empty input. Every check below
# routes JSON access through one of these instead of inline `python3 -c "...json.load..."`, so a
# down Synapse/Element (empty curl response, HTML error page, connection refused) always turns
# into a clean FAIL line rather than a Python traceback dumped mid-run.
# ---------------------------------------------------------------------------
json_field() {
  # args: <json-string> <key> [default]  -- top-level string/scalar field lookup
  local json="$1" key="$2" default="${3:-}"
  python3 -c "
import json, sys
raw, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(raw)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
val = d.get(key, default)
print(val if val is not None else default)
" "${json}" "${key}" "${default}" 2>/dev/null
}

json_list_contains() {
  # args: <json-string> <list-key> <value> -- prints 1/0, never raises
  local json="$1" key="$2" value="$3"
  python3 -c "
import json, sys
raw, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(raw)
except Exception:
    d = {}
lst = d.get(key, []) if isinstance(d, dict) else []
if not isinstance(lst, list):
    lst = []
print('1' if value in lst else '0')
" "${json}" "${key}" "${value}" 2>/dev/null
}

json_chunk_has_body() {
  # args: <json-string /messages response> <body text> -- prints 1/0, never raises
  local json="$1" body="$2"
  python3 -c "
import json, sys
raw, body = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    d = {}
chunk = d.get('chunk', []) if isinstance(d, dict) else []
if not isinstance(chunk, list):
    chunk = []
found = any(isinstance(e, dict) and e.get('content', {}).get('body') == body for e in chunk)
print('1' if found else '0')
" "${json}" "${body}" 2>/dev/null
}

cleanup() {
  if [[ -n "${REG_SHARED_SECRET:-}" ]]; then
    for u in "${CLEANUP_USERS[@]:-}"; do
      [[ -z "${u}" ]] && continue
      # deactivate via admin API using admin token if we have one
      if [[ -n "${ADMIN_TOKEN:-}" ]]; then
        curl -s -X POST "${SYNAPSE_URL}/_synapse/admin/v1/deactivate/@${u}:${SERVER_NAME}" \
          -H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json" \
          -d '{"erase": true}' >/dev/null 2>&1 || true
      fi
    done
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Synapse versions endpoint
# ---------------------------------------------------------------------------
VERSIONS_JSON="$(curl -fsS "${SYNAPSE_URL}/_matrix/client/versions" 2>/dev/null || true)"
VERSIONS_OK=0
[[ -n "$(json_field "${VERSIONS_JSON}" versions)" ]] && VERSIONS_OK=1
check "Synapse /_matrix/client/versions responds" "${VERSIONS_OK}" "no/invalid response from ${SYNAPSE_URL}"

# ---------------------------------------------------------------------------
# 2. Element served + config.json brand/welcome_user_id + welcome.html rendered
# ---------------------------------------------------------------------------
ELEMENT_HTML="$(curl -fsS "${ELEMENT_URL}/" 2>/dev/null || true)"
ELEMENT_UP=0
[[ -n "${ELEMENT_HTML}" ]] && ELEMENT_UP=1
check "Element Web served at ${ELEMENT_URL}" "${ELEMENT_UP}" "empty/no response from ${ELEMENT_URL}"

CONFIG_JSON="$(curl -fsS "${ELEMENT_URL}/config.json" 2>/dev/null || true)"
BRAND="$(json_field "${CONFIG_JSON}" brand)"
WELCOME="$(json_field "${CONFIG_JSON}" welcome_user_id)"
BRAND_OK=0; [[ "${BRAND}" == "Rumi" ]] && BRAND_OK=1
WELCOME_OK=0; [[ "${WELCOME}" == "@rumi:${SERVER_NAME}" ]] && WELCOME_OK=1
check "Element config.json brand == \"Rumi\"" "${BRAND_OK}" "got brand='${BRAND}'"
check "Element config.json welcome_user_id == @rumi:${SERVER_NAME}" "${WELCOME_OK}" "got welcome_user_id='${WELCOME}'"

# welcome.html (logged-out, #/welcome) must be the RENDERED file (setup.sh substitutes
# __SERVER_NAME__ / __PUBLIC_BASE_URL__ from welcome.template.html) -- Element's HTML sanitizer
# blocks any client-side templating, so a literal placeholder reaching the browser is a real bug,
# not cosmetic. It no longer references @rumi directly (a logged-out, disable_guests visitor
# can't open a chat pre-auth) -- it points to register/login instead, so this check only proves
# the template rendered, not raw placeholder text.
WELCOME_HTML="$(curl -fsS "${ELEMENT_URL}/welcome.html" 2>/dev/null || true)"
WELCOME_HTML_OK=0
if [[ -n "${WELCOME_HTML}" ]] \
  && echo "${WELCOME_HTML}" | grep -qF "#/register" \
  && ! echo "${WELCOME_HTML}" | grep -qF "__SERVER_NAME__"; then
  WELCOME_HTML_OK=1
fi
check "Element welcome.html rendered (#/register link, no __SERVER_NAME__ placeholder)" "${WELCOME_HTML_OK}" \
  "empty response, missing #/register, or literal __SERVER_NAME__ still present"

# home.html (logged-in, no-rooms #/home) is where the @rumi:<server> reference now lives (setup.sh
# substitutes it from home.template.html) -- this is the real "one tap to Rumi" placement surface
# once welcome_user_id was found to be dead code upstream (see docs/DECISIONS.tsv).
HOME_HTML="$(curl -fsS "${ELEMENT_URL}/home.html" 2>/dev/null || true)"
HOME_HTML_OK=0
if [[ -n "${HOME_HTML}" ]] \
  && echo "${HOME_HTML}" | grep -qF "@rumi:${SERVER_NAME}" \
  && ! echo "${HOME_HTML}" | grep -qF "__SERVER_NAME__"; then
  HOME_HTML_OK=1
fi
check "Element home.html rendered (@rumi:${SERVER_NAME}, no __SERVER_NAME__ placeholder)" "${HOME_HTML_OK}" \
  "empty response, missing @rumi:${SERVER_NAME}, or literal __SERVER_NAME__ still present"

# ---------------------------------------------------------------------------
# 3. register two throwaway users via the shared secret registrar
# ---------------------------------------------------------------------------
register_via_secret() {
  # Implements the Synapse shared-secret registration HMAC handshake (v2), used so this
  # script has no dependency on `docker compose exec` / register_new_matrix_user, only curl.
  local username="$1" password="$2" admin="$3"
  local nonce_json nonce mac body resp
  nonce_json="$(curl -fsS "${SYNAPSE_URL}/_synapse/admin/v1/register" 2>/dev/null || true)"
  nonce="$(json_field "${nonce_json}" nonce)"
  if [[ -z "${nonce}" ]]; then
    echo "{}"
    return
  fi
  mac="$(python3 - "$nonce" "$username" "$password" "$admin" "${REG_SHARED_SECRET:-}" <<'PYEOF' 2>/dev/null
import hashlib, hmac, sys
nonce, username, password, admin, secret = sys.argv[1:6]
msg = b"\x00".join([nonce.encode(), username.encode(), password.encode(), admin.encode()])
print(hmac.new(secret.encode(), msg, hashlib.sha1).hexdigest())
PYEOF
)"
  if [[ -z "${mac}" ]]; then
    echo "{}"
    return
  fi
  body="$(python3 - "$nonce" "$username" "$password" "$admin" "$mac" <<'PYEOF' 2>/dev/null
import json, sys
nonce, username, password, admin, mac = sys.argv[1:6]
print(json.dumps({
    "nonce": nonce, "username": username, "password": password,
    "admin": admin == "admin", "mac": mac,
}))
PYEOF
)"
  resp="$(curl -fsS -X POST "${SYNAPSE_URL}/_synapse/admin/v1/register" -H "Content-Type: application/json" -d "${body}" 2>/dev/null || true)"
  echo "${resp:-\{\}}"
}

EPOCH="$(date +%s)"
USER_A="e2e-${EPOCH}-a"
USER_B="e2e-${EPOCH}-b"
PASSWORD="e2e-Passw0rd-${EPOCH}"

RESP_A="$(register_via_secret "${USER_A}" "${PASSWORD}" notadmin)"
RESP_B="$(register_via_secret "${USER_B}" "${PASSWORD}" notadmin)"
TOKEN_A="$(json_field "${RESP_A}" access_token)"
TOKEN_B="$(json_field "${RESP_B}" access_token)"
CLEANUP_USERS+=("${USER_A}" "${USER_B}")

REGISTER_OK=0
[[ -n "${TOKEN_A}" && -n "${TOKEN_B}" ]] && REGISTER_OK=1
check "register throwaway users ${USER_A} / ${USER_B}" "${REGISTER_OK}" \
  "A error='$(json_field "${RESP_A}" error)' B error='$(json_field "${RESP_B}" error)'"

# admin token for cleanup: log in as configured admin
ADMIN_LOGIN="$(curl -fsS -X POST "${SYNAPSE_URL}/_matrix/client/v3/login" -H "Content-Type: application/json" \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${ADMIN_USER:-admin}\"},\"password\":\"${ADMIN_PASSWORD:-}\"}" \
  2>/dev/null || true)"
ADMIN_TOKEN="$(json_field "${ADMIN_LOGIN}" access_token)"

mxc_call() {
  local method="$1" token="$2" path="$3" data="${4:-}"
  if [[ -n "${data}" ]]; then
    curl -fsS -X "${method}" "${SYNAPSE_URL}${path}" -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" -d "${data}" 2>/dev/null || true
  else
    curl -fsS -X "${method}" "${SYNAPSE_URL}${path}" -H "Authorization: Bearer ${token}" 2>/dev/null || true
  fi
}

# If registration itself failed there is no point (and no way, tokens are empty) to run the
# room/messaging checks below -- report them as clean FAILs instead of noise from empty tokens.
if [[ "${REGISTER_OK}" == "1" ]]; then

  # -------------------------------------------------------------------------
  # 4. user A auto-joined to #rumi-announcements
  # -------------------------------------------------------------------------
  sleep 1
  JOINED_ROOMS="$(mxc_call GET "${TOKEN_A}" "/_matrix/client/v3/joined_rooms")"
  ALIAS_RESOLVE="$(curl -fsS "${SYNAPSE_URL}/_matrix/client/v3/directory/room/%23rumi-announcements:${SERVER_NAME}" \
    -H "Authorization: Bearer ${TOKEN_A}" 2>/dev/null || true)"
  ANNOUNCE_ROOM_ID="$(json_field "${ALIAS_RESOLVE}" room_id)"
  AUTO_JOIN_OK=0
  if [[ -n "${ANNOUNCE_ROOM_ID}" ]] && [[ "$(json_list_contains "${JOINED_ROOMS}" joined_rooms "${ANNOUNCE_ROOM_ID}")" == "1" ]]; then
    AUTO_JOIN_OK=1
  fi
  check "user A auto-joined #rumi-announcements" "${AUTO_JOIN_OK}" "room_id='${ANNOUNCE_ROOM_ID}'"

  # -------------------------------------------------------------------------
  # 5. A creates a DM with B, sends text, B reads it back
  # -------------------------------------------------------------------------
  CREATE_DM_RESP="$(mxc_call POST "${TOKEN_A}" "/_matrix/client/v3/createRoom" "{\"is_direct\":true,\"invite\":[\"@${USER_B}:${SERVER_NAME}\"],\"preset\":\"trusted_private_chat\"}")"
  DM_ROOM_ID="$(json_field "${CREATE_DM_RESP}" room_id)"

  if [[ -n "${DM_ROOM_ID}" ]]; then
    mxc_call POST "${TOKEN_B}" "/_matrix/client/v3/join/${DM_ROOM_ID}" "{}" >/dev/null
    MSG_TXT="hello-from-a-${EPOCH}"
    mxc_call PUT "${TOKEN_A}" "/_matrix/client/v3/rooms/${DM_ROOM_ID}/send/m.room.message/txn-${EPOCH}-1" \
      "{\"msgtype\":\"m.text\",\"body\":\"${MSG_TXT}\"}" >/dev/null
    sleep 1
    MESSAGES="$(mxc_call GET "${TOKEN_B}" "/_matrix/client/v3/rooms/${DM_ROOM_ID}/messages?dir=b&limit=10")"
    DM_OK=0
    [[ "$(json_chunk_has_body "${MESSAGES}" "${MSG_TXT}")" == "1" ]] && DM_OK=1
    check "A -> B DM roundtrip (send + readback)" "${DM_OK}" "room='${DM_ROOM_ID}'"
  else
    check "A -> B DM roundtrip (send + readback)" 0 "createRoom failed: error='$(json_field "${CREATE_DM_RESP}" error)'"
  fi

  # -------------------------------------------------------------------------
  # 6. A sends a text to a DM with @rumi and the message lands in the room
  #    (the bot's reply, i.e. rumi-platform actually responding, is out of scope here)
  # -------------------------------------------------------------------------
  RUMI_DM_RESP="$(mxc_call POST "${TOKEN_A}" "/_matrix/client/v3/createRoom" "{\"is_direct\":true,\"invite\":[\"@rumi:${SERVER_NAME}\"],\"preset\":\"trusted_private_chat\"}")"
  RUMI_DM_ROOM_ID="$(json_field "${RUMI_DM_RESP}" room_id)"
  if [[ -n "${RUMI_DM_ROOM_ID}" ]]; then
    RUMI_MSG_TXT="hello-rumi-${EPOCH}"
    mxc_call PUT "${TOKEN_A}" "/_matrix/client/v3/rooms/${RUMI_DM_ROOM_ID}/send/m.room.message/txn-${EPOCH}-2" \
      "{\"msgtype\":\"m.text\",\"body\":\"${RUMI_MSG_TXT}\"}" >/dev/null
    sleep 1
    # Verify from A's own view that the event landed in the room (bot reply not required).
    ROOM_MESSAGES="$(mxc_call GET "${TOKEN_A}" "/_matrix/client/v3/rooms/${RUMI_DM_ROOM_ID}/messages?dir=b&limit=10")"
    RUMI_MSG_OK=0
    [[ "$(json_chunk_has_body "${ROOM_MESSAGES}" "${RUMI_MSG_TXT}")" == "1" ]] && RUMI_MSG_OK=1
    check "A -> @rumi DM message lands in room" "${RUMI_MSG_OK}" "room='${RUMI_DM_ROOM_ID}'"
  else
    check "A -> @rumi DM message lands in room" 0 "createRoom failed: error='$(json_field "${RUMI_DM_RESP}" error)'"
  fi

else
  check "user A auto-joined #rumi-announcements" 0 "skipped: user registration failed"
  check "A -> B DM roundtrip (send + readback)" 0 "skipped: user registration failed"
  check "A -> @rumi DM message lands in room" 0 "skipped: user registration failed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "================================================================"
echo " e2e summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
exit 0
