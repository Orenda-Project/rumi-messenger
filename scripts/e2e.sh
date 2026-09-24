#!/usr/bin/env bash
# Rumi Messenger -- end-to-end verification. Exits non-zero if any check fails.
# Prints one clean PASS/FAIL line per check (never a Python traceback, even if Synapse/Element
# are down) and moves on. Requires: bash, curl, python3, docker (for the coturn liveness check
# only -- everything else is pure curl/python3). Run scripts/setup.sh first.
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
TURN_PORT="${TURN_PORT:-3478}"
RUMI_CONTAINER_PREFIX="${RUMI_CONTAINER_PREFIX:-rumi}"
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

json_results_contains_user() {
  # args: <json-string /user_directory/search response> <user_id> -- prints 1/0, never raises.
  # Response shape is {"results": [{"user_id": "...", "display_name": "...", ...}, ...], "limited": bool}.
  local json="$1" user_id="$2"
  python3 -c "
import json, sys
raw, user_id = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    d = {}
results = d.get('results', []) if isinstance(d, dict) else []
if not isinstance(results, list):
    results = []
found = any(isinstance(r, dict) and r.get('user_id') == user_id for r in results)
print('1' if found else '0')
" "${json}" "${user_id}" 2>/dev/null
}

json_list_nonempty() {
  # args: <json-string> <list-key> -- prints 1/0, never raises. Used for turnServer's "uris",
  # where we only care that Synapse handed back at least one, not which.
  local json="$1" key="$2"
  python3 -c "
import json, sys
raw, key = sys.argv[1], sys.argv[2]
try:
    d = json.loads(raw)
except Exception:
    d = {}
lst = d.get(key, []) if isinstance(d, dict) else []
print('1' if isinstance(lst, list) and len(lst) > 0 else '0')
" "${json}" "${key}" 2>/dev/null
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

# Federation is OFF (issue #8): the federation API must not be served at all. Synapse answers
# 404 when the `federation` resource is absent from the listener; 200 here means the listener
# still serves it (setup.sh not re-run, or someone re-added it).
FED_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${SYNAPSE_URL}/_matrix/federation/v1/version" 2>/dev/null || echo 000)"
FED_CLOSED=0
[[ "${FED_CODE}" == "404" ]] && FED_CLOSED=1
check "Federation API not served (federation OFF, #8)" "${FED_CLOSED}" "GET /_matrix/federation/v1/version returned HTTP ${FED_CODE}, expected 404"

# ...but the stand-alone `openid` resource IS served (issue #2): lk-jwt-service verifies teachers'
# OpenID tokens at /_matrix/federation/v1/openid/userinfo. With a bogus token Synapse answers 401
# (endpoint present, token rejected); 404 would mean the resource is missing again.
OID_CODE="$(curl -s -o /dev/null -w '%{http_code}' "${SYNAPSE_URL}/_matrix/federation/v1/openid/userinfo?access_token=bogus" 2>/dev/null || echo 000)"
OID_OK=0
[[ "${OID_CODE}" == "401" ]] && OID_OK=1
check "OpenID userinfo endpoint served for call auth (#2)" "${OID_OK}" "GET /_matrix/federation/v1/openid/userinfo returned HTTP ${OID_CODE}, expected 401"

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

  # -------------------------------------------------------------------------
  # 7. TURN credentials for calls (issue #1). Two checks, deliberately separate:
  #
  #    (a) Synapse's own turnServer endpoint returns a non-empty, well-shaped response.
  #        IMPORTANT: Synapse computes this ENTIRELY locally from turn_shared_secret in its own
  #        config -- it never contacts coturn to produce it. This check on its own proves only
  #        that homeserver.yaml is wired correctly; it PASSES even if coturn is dead (caught in
  #        review -- an earlier version of this script had only this check, so `e2e.sh` could
  #        report a healthy calling setup with coturn stopped the entire time).
  #    (b) coturn itself is actually alive and accepts those EXACT credentials for a real TURN
  #        ALLOCATE. This is the one that can fail. Runs turnutils_uclient (already inside the
  #        coturn image, no new dependency beyond docker) via `docker exec` rather than curling
  #        coturn directly, because BIND_ADDR may legitimately keep coturn off the host network
  #        entirely (127.0.0.1-only local testing) the same way Synapse/Element are -- `docker
  #        exec` reaches it from inside its own container regardless of what it's bound to on
  #        the host. A successful ALLOCATE (logged as "Received relay addr") proves auth +
  #        liveness together; the subsequent channel-bind failing with 403 is coturn's own
  #        deliberate denied-peer-ip-for-loopback protection kicking in (see docs/RUNBOOK.md),
  #        not an auth problem, so this check does not require it to succeed.
  #
  #    Neither proves NAT traversal between two real devices; see docs/RUNBOOK.md for why that
  #    can't be checked from one machine.
  # -------------------------------------------------------------------------
  TURN_JSON="$(mxc_call GET "${TOKEN_A}" "/_matrix/client/v3/voip/turnServer")"
  TURN_URIS_OK=0
  [[ "$(json_list_nonempty "${TURN_JSON}" uris)" == "1" ]] && TURN_URIS_OK=1
  TURN_USERNAME="$(json_field "${TURN_JSON}" username)"
  TURN_PASSWORD="$(json_field "${TURN_JSON}" password)"
  TURN_TTL="$(json_field "${TURN_JSON}" ttl)"
  TURN_OK=0
  if [[ "${TURN_URIS_OK}" == "1" && -n "${TURN_USERNAME}" && -n "${TURN_PASSWORD}" && -n "${TURN_TTL}" ]]; then
    TURN_OK=1
  fi
  check "GET /_matrix/client/v3/voip/turnServer returns TURN credentials (Synapse-side config only -- does NOT prove coturn is up, see next check)" "${TURN_OK}" \
    "uris_nonempty=${TURN_URIS_OK} username='${TURN_USERNAME}' password_set=$([[ -n "${TURN_PASSWORD}" ]] && echo yes || echo no) ttl='${TURN_TTL}'"

  COTURN_CONTAINER="${RUMI_CONTAINER_PREFIX}-coturn"
  TURN_LIVE_OK=0
  TURN_LIVE_DETAIL="skipped: no credentials to test (previous check failed)"
  if [[ "${TURN_OK}" == "1" ]]; then
    if [[ "$(docker inspect -f '{{.State.Running}}' "${COTURN_CONTAINER}" 2>/dev/null)" != "true" ]]; then
      TURN_LIVE_DETAIL="container ${COTURN_CONTAINER} not found or not running"
    else
      # Bounded with `timeout`: wrong/stale credentials make turnutils_uclient retry allocate
      # for ~15s before giving up (verified live) rather than failing fast -- a real "coturn is
      # dead" case fails via docker exec itself, near-instantly.
      UCLIENT_OUT="$(timeout 20 docker exec "${COTURN_CONTAINER}" \
        turnutils_uclient -p "${TURN_PORT}" -u "${TURN_USERNAME}" -w "${TURN_PASSWORD}" -y -v -n 1 127.0.0.1 2>&1)"
      if echo "${UCLIENT_OUT}" | grep -q "Received relay addr"; then
        TURN_LIVE_OK=1
      else
        TURN_LIVE_DETAIL="turnutils_uclient never completed an ALLOCATE with these credentials -- last lines: $(echo "${UCLIENT_OUT}" | tail -3 | tr '\n' ' ')"
      fi
    fi
  fi
  check "coturn is alive and honors the Synapse-issued TURN credentials (docker exec turnutils_uclient ALLOCATE)" "${TURN_LIVE_OK}" "${TURN_LIVE_DETAIL}"

  # -------------------------------------------------------------------------
  # 7b. The call transport Synapse ADVERTISES must actually work (Element X can only call
  #     through Element Call, so a dead address here = the phone can never call). Falsifiable:
  #     stop lk-jwt-service, or advertise https://localhost/livekit/jwt with no Caddy (the QA
  #     critic's OPEN_ID_ERROR), and this FAILs. Uses A's real OpenID token -> /sfu/get -> JWT.
  #     Nothing advertised (CALLS=off) is a PASS: no client is sent anywhere.
  # -------------------------------------------------------------------------
  RTC_JSON="$(curl -s -H "Authorization: Bearer ${TOKEN_A}" "${SYNAPSE_URL}/_matrix/client/unstable/org.matrix.msc4143/rtc/transports" 2>/dev/null || true)"
  RTC_URL="$(python3 -c "
import json,sys
try: d=json.loads(sys.argv[1])
except Exception: d={}
t=[x for x in d.get('rtc_transports',[]) if x.get('type')=='livekit'] if isinstance(d,dict) else []
print(t[0].get('livekit_service_url','') if t else '')
" "${RTC_JSON}" 2>/dev/null)"
  if [[ -z "${RTC_URL}" ]]; then
    RTC_OK=1; RTC_DETAIL="no call transport advertised"
  else
    OID_JSON="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN_A}" -H 'Content-Type: application/json' -d '{}' \
      "${SYNAPSE_URL}/_matrix/client/v3/user/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "@${USER_A}:${SERVER_NAME}")/openid/request_token" 2>/dev/null || true)"
    SFU_BODY="$(python3 -c "
import json,sys
try: o=json.loads(sys.argv[1])
except Exception: o={}
print(json.dumps({'room':'!e2e-call:'+sys.argv[2],'device_id':'E2E','openid_token':o}))
" "${OID_JSON}" "${SERVER_NAME}" 2>/dev/null)"
    SFU_OUT="$(curl -sk --max-time 40 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' -d "${SFU_BODY}" "${RTC_URL%/}/sfu/get" 2>/dev/null || true)"
    SFU_CODE="${SFU_OUT##*$'\n'}"; SFU_RESP="${SFU_OUT%$'\n'*}"
    RTC_OK=0; [[ "${SFU_CODE}" == "200" && -n "$(json_field "${SFU_RESP}" jwt)" ]] && RTC_OK=1
    RTC_DETAIL="POST ${RTC_URL}/sfu/get -> HTTP ${SFU_CODE:-000} ${SFU_RESP:0:160}"
  fi
  check "advertised call transport answers a real OpenID token with a LiveKit JWT (${RTC_URL:-none advertised})" "${RTC_OK}" "${RTC_DETAIL}"

  # -------------------------------------------------------------------------
  # 8. User directory search (issue #10, "give teachers a way to find each other"). Two checks,
  #    deliberately both against A's own throwaway account -- freshly created seconds ago in
  #    check #3 above -- to prove the search_all_users/prefer_local_users config
  #    (scripts/setup.sh) actually makes a brand-new account discoverable, not just that some
  #    pre-existing/reindexed account is:
  #      (a) full first-name search_term finds the user
  #      (b) a partial (prefix) search_term also finds the user -- proves it isn't an
  #          exact-full-name-only search, which would be useless for a real "type a few letters"
  #          UI. NOTE: verified live that Synapse's user_directory search matches by WORD PREFIX
  #          (tokenizes the display name, then prefix-matches each token), not arbitrary substring
  #          -- "Tea" matches "... Teacher", but "eacher" (missing the leading "T") does not. This
  #          check uses a real word-prefix ("Tea", from the second word of the display name set
  #          below) for exactly that reason; do not "simplify" it back to a mid-word substring.
  #    Both poll (bounded, 1s steps) rather than checking once immediately -- the directory can
  #    lag a live profile-name update by a moment, and a flaky one-shot check would be a false
  #    FAIL, not a real bug.
  #    The searcher is a THIRD throwaway user, C, who first LEAVES #rumi-announcements. Without
  #    that, C (or B) would share the auto-join room with A, and Synapse returns shared-room users
  #    even with search_all_users off -- a reviewer proved the earlier version of this check passed
  #    with the flag disabled. Once C shares no room with A, the only way this search can succeed
  #    is search_all_users doing its job, so the check now fails when the flag is off.
  # -------------------------------------------------------------------------
  USER_C="e2e-${EPOCH}-c"
  RESP_C="$(register_via_secret "${USER_C}" "${PASSWORD}" notadmin)"
  TOKEN_C="$(json_field "${RESP_C}" access_token)"
  CLEANUP_USERS+=("${USER_C}")
  if [[ -n "${TOKEN_C}" && -n "${ANNOUNCE_ROOM_ID:-}" ]]; then
    for attempt in $(seq 1 10); do   # auto-join is async; wait until C is in, then leave
      C_ROOMS="$(mxc_call GET "${TOKEN_C}" "/_matrix/client/v3/joined_rooms" "")"
      if python3 -c "import json,sys; sys.exit(0 if sys.argv[2] in json.loads(sys.argv[1]).get('joined_rooms',[]) else 1)" "${C_ROOMS}" "${ANNOUNCE_ROOM_ID}" 2>/dev/null; then break; fi
      sleep 1
    done
    ROOM_ENC="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "${ANNOUNCE_ROOM_ID}")"
    mxc_call POST "${TOKEN_C}" "/_matrix/client/v3/rooms/${ROOM_ENC}/leave" "{}" >/dev/null
    # A leaves too: #rumi-announcements is PUBLIC, and Synapse lists members of public rooms in
    # the directory for everyone even with search_all_users off. With A in no public room and
    # sharing nothing with C, only search_all_users can make A findable. (Verified: with only C
    # leaving, the checks still passed with the flag off.) All earlier checks that need A in the
    # room have already run at this point.
    mxc_call POST "${TOKEN_A}" "/_matrix/client/v3/rooms/${ROOM_ENC}/leave" "{}" >/dev/null
  fi
  USER_A_MXID="@${USER_A}:${SERVER_NAME}"
  DISPLAY_FIRST="Ee2eFind${EPOCH}"
  # The second word carries the epoch too (not a bare "Teacher") -- a real teacher fixture
  # account (created by hand, by teacher.sh, or by another test run) can accumulate in this
  # directory over the life of a deployment and will always be a real word like "Teacher" or
  # "Teacher One", never one with a run-specific epoch glued on. Reproduced live: with a bare
  # "Teacher" second word and the literal search term "Tea", 10 real "Teacher"-named fixture
  # accounts created by other test/setup runs filled Synapse's directory-search result window
  # (limit=10) and silently pushed this run's own throwaway target out of the results -- a
  # real, reproducible failure, not a flake.
  DISPLAY_NAME="${DISPLAY_FIRST} Teacher${EPOCH}"
  mxc_call PUT "${TOKEN_A}" "/_matrix/client/v3/profile/${USER_A_MXID}/displayname" \
    "{\"displayname\":\"${DISPLAY_NAME}\"}" >/dev/null

  poll_user_directory_search() {
    # args: <token> <search_term> <target_user_id> -- prints 1/0, polls up to 10x 1s
    local token="$1" term="$2" target="$3" attempt resp
    for attempt in $(seq 1 10); do
      resp="$(mxc_call POST "${token}" "/_matrix/client/v3/user_directory/search" "{\"search_term\":\"${term}\",\"limit\":10}")"
      if [[ "$(json_results_contains_user "${resp}" "${target}")" == "1" ]]; then
        echo "1"
        return 0
      fi
      sleep 1
    done
    echo "0"
  }

  FULL_NAME_SEARCH_OK="$(poll_user_directory_search "${TOKEN_C}" "${DISPLAY_FIRST}" "${USER_A_MXID}")"
  check "user_directory/search by full first name finds a user who shares NO room with the searcher (proves search_all_users)" "${FULL_NAME_SEARCH_OK}" \
    "search_term='${DISPLAY_FIRST}' target='${USER_A_MXID}'"

  # A genuine partial/word-prefix search: shorter than the actual word "Teacher${EPOCH}",
  # but epoch-unique so it can never collide with a real fixture's plain "Teacher" or "Teacher
  # One"/"Teacher Two" style name, however many accumulate in this directory over time.
  PARTIAL_SEARCH_TERM="Teacher${EPOCH:0:4}"
  PARTIAL_NAME_SEARCH_OK="$(poll_user_directory_search "${TOKEN_C}" "${PARTIAL_SEARCH_TERM}" "${USER_A_MXID}")"
  check "user_directory/search by partial (word-prefix) display name finds the same user" "${PARTIAL_NAME_SEARCH_OK}" \
    "search_term='${PARTIAL_SEARCH_TERM}' target='${USER_A_MXID}'"

else
  check "user A auto-joined #rumi-announcements" 0 "skipped: user registration failed"
  check "A -> B DM roundtrip (send + readback)" 0 "skipped: user registration failed"
  check "A -> @rumi DM message lands in room" 0 "skipped: user registration failed"
  check "GET /_matrix/client/v3/voip/turnServer returns TURN credentials (Synapse-side config only -- does NOT prove coturn is up, see next check)" 0 "skipped: user registration failed"
  check "coturn is alive and honors the Synapse-issued TURN credentials (docker exec turnutils_uclient ALLOCATE)" 0 "skipped: user registration failed"
  check "advertised call transport answers a real OpenID token with a LiveKit JWT" 0 "skipped: user registration failed"
  check "user_directory/search by full first name finds a user who shares NO room with the searcher (proves search_all_users)" 0 "skipped: user registration failed"
  check "user_directory/search by partial (word-prefix) display name finds the same user" 0 "skipped: user registration failed"
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
