#!/usr/bin/env bash
# Rumi Messenger -- Sygnal (push gateway) verification. Proves the wiring without a phone.
# Exits non-zero if the gateway itself is unreachable or malfunctioning. A "credentials missing"
# result is reported as a clear, separate line, NOT as a failure of the check -- that's the
# expected, honest state until docs/PUSH.md's three manual steps are done. This script never
# claims a notification was delivered to a real device; it cannot prove that.
#
# Requires: bash, curl, python3. Run scripts/push-setup.sh (or `docker compose --profile push up
# -d sygnal`) first.
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

BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
SYGNAL_PORT="${SYGNAL_PORT:-5000}"
PUSH_APP_ID="${PUSH_APP_ID:-ai.hellorumi.messenger}"
SYGNAL_URL="http://${BIND_ADDR}:${SYGNAL_PORT}"

PASS_COUNT=0
FAIL_COUNT=0

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

json_list_contains() {
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

# ---------------------------------------------------------------------------
# A. Self-hosted ntfy (UnifiedPush, the no-Google path). Falsifiable end to end on this machine:
#    health, the exact discovery JSON Element X's UnifiedPushGatewayResolver requires, the
#    deny-all ACL, and a Matrix-gateway publish that must reach a live subscriber.
# ---------------------------------------------------------------------------
NTFY_PORT="${NTFY_PORT:-2586}"
NTFY_URL="http://${BIND_ADDR}:${NTFY_PORT}"
NTFY_BASE_URL="${NTFY_BASE_URL:-https://ntfy.${PUBLIC_DOMAIN:-localhost}}"

NTFY_HEALTH="$(curl -s --max-time 5 "${NTFY_URL}/v1/health" 2>/dev/null || true)"
NH_OK=0; [[ "${NTFY_HEALTH}" == *'"healthy":true'* ]] && NH_OK=1
check "ntfy GET /v1/health is healthy" "${NH_OK}" "got '${NTFY_HEALTH}' from ${NTFY_URL} -- is it up? (scripts/push-setup.sh)"

DISC="$(curl -s --max-time 5 "${NTFY_URL}/_matrix/push/v1/notify" 2>/dev/null || true)"
DISC_OK="$(python3 -c "import json,sys
try: print('1' if json.loads(sys.argv[1])['unifiedpush']['gateway']=='matrix' else '0')
except Exception: print('0')" "${DISC}")"
check "GET /_matrix/push/v1/notify returns the UnifiedPush gateway discovery JSON" "${DISC_OK}" "got '${DISC}'"

DENY_HTTP="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -d x "${NTFY_URL}/pushcheck-not-up-topic" 2>/dev/null || true)"
DENY_OK=0; [[ "${DENY_HTTP}" == "403" ]] && DENY_OK=1
check "non-UnifiedPush topic publish is denied (deny-all ACL)" "${DENY_OK}" "http_code='${DENY_HTTP}', want 403"

# Subscribe to a fresh up* topic, publish a Matrix push-gateway notification whose pushkey is
# <NTFY_BASE_URL>/<topic> (ntfy rejects any pushkey not prefixed by its base-url), and require
# the subscriber stream to carry that event id.
# Exactly "up" + 12 chars: ntfy only applies subscriber-based rate limiting (on in compose) to
# 14-char up* topics, and with it on, a publish to a topic with no rate visitor gets HTTP 507.
UP_TOPIC="up$(python3 -c 'import secrets,string;print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(12)))')"
SUB_OUT="$(mktemp)"
curl -s -N --max-time 8 "${NTFY_URL}/${UP_TOPIC}/json" > "${SUB_OUT}" 2>/dev/null &
SUB_PID=$!
sleep 2
EVT="\$pushcheck$(date +%s)"
GW_RESP="$(curl -s --max-time 5 -X POST "${NTFY_URL}/_matrix/push/v1/notify" -H 'Content-Type: application/json' \
  -d "{\"notification\":{\"event_id\":\"${EVT}\",\"room_id\":\"!pushcheck:localhost\",\"counts\":{\"unread\":1},\"devices\":[{\"app_id\":\"push-check\",\"pushkey\":\"${NTFY_BASE_URL}/${UP_TOPIC}?up=1\"}]}}" 2>/dev/null || true)"
wait "${SUB_PID}" 2>/dev/null
DELIV_OK=0; grep -q "pushcheck" "${SUB_OUT}" && [[ "${GW_RESP}" == '{"rejected":[]}' ]] && DELIV_OK=1
check "Matrix gateway publish reaches a live up* subscriber" "${DELIV_OK}" "gateway said '${GW_RESP}'; subscriber saw: $(tr '\n' ' ' < "${SUB_OUT}" | cut -c1-200)"
rm -f "${SUB_OUT}"
echo "INFO: this proves ntfy end to end on this box. Synapse must also be able to reach ${NTFY_BASE_URL} at a NON-private IP (Synapse blocks private ranges for pushers by default) -- see docs/PUSH.md."

# ---------------------------------------------------------------------------
# B. Sygnal (FCM, the Google path) -- only checked once scripts/push-setup.sh configured a
#    real FCM pushkin. Without one, Sygnal cannot even start (see docs/PUSH.md), so there is
#    nothing to check and that is not a failure of the no-Google path above.
# ---------------------------------------------------------------------------
if ! grep -q 'type: gcm' "${DEPLOY_DIR}/sygnal/sygnal.yaml" 2>/dev/null; then
  echo "INFO: Sygnal/FCM not configured (no real FCM service account) -- skipping Sygnal checks."
  echo
  echo "================================================================"
  echo " push-check summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  echo "================================================================"
  [[ "${FAIL_COUNT}" -gt 0 ]] && exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. GET /health
# ---------------------------------------------------------------------------
# NOTE: curl's -w '%{http_code}' already prints "000" on a connection failure (exit 7) before
# returning that non-zero exit -- do NOT add `|| echo 000` here, it would concatenate a second
# "000" onto curl's own output inside this $(...) capture (curl's stdout is emitted regardless
# of its exit code, so a fallback `echo` after `||` appends rather than replaces). Bare `|| true`
# only, so a connection failure still yields curl's own honest "000".
HEALTH_HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${SYGNAL_URL}/health" 2>/dev/null || true)"
HEALTH_HTTP="${HEALTH_HTTP:-000}"
HEALTH_OK=0
[[ "${HEALTH_HTTP}" == "200" ]] && HEALTH_OK=1
check "Sygnal GET /health responds 200" "${HEALTH_OK}" "http_code='${HEALTH_HTTP}' from ${SYGNAL_URL}/health -- is it running? (scripts/push-setup.sh or docker compose --profile push up -d sygnal)"

if [[ "${HEALTH_OK}" != "1" ]]; then
  echo
  echo "================================================================"
  echo " push-check summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  echo " Sygnal is unreachable -- skipping the /notify check entirely."
  echo "================================================================"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. POST a synthetic /_matrix/push/v1/notify for PUSH_APP_ID with a fake pushkey.
#
# Per Sygnal's own dispatch code (sygnal/http.py, _handle_dispatch): an app id with no matching
# pushkin configured is reported back as {"rejected": [<pushkey>]} with HTTP 200 -- this is NOT
# an error, it is the documented "no pushkin handles this app id" path. That is exactly the
# state we're in with no real FCM credentials (scripts/push-setup.sh renders sygnal.yaml with
# zero apps configured in that case), so we can tell three states apart from one HTTP call:
#
#   (a) connection refused / non-200 / unparsable body -> gateway itself is broken (FAIL)
#   (b) 200, our pushkey IS in "rejected"               -> gateway reachable, request parsed,
#                                                           but PUSH_APP_ID has no working
#                                                           pushkin -- i.e. credentials missing
#   (c) 200, our pushkey is NOT in "rejected"            -> a pushkin for PUSH_APP_ID accepted
#                                                           the notification for delivery. This
#                                                           does NOT mean it reached a real
#                                                           device -- Sygnal only reports a
#                                                           rejection when the PROVIDER (Firebase)
#                                                           tells it the pushkey is invalid/
#                                                           unregistered; a fake pushkey against
#                                                           real credentials is typically rejected
#                                                           on the FIRST real send, so seeing it
#                                                           accepted here with a synthetic pushkey
#                                                           is unusual and worth a second look
#                                                           (see the printed detail below), never
#                                                           reported as "delivered".
# ---------------------------------------------------------------------------
EPOCH="$(date +%s)"
FAKE_PUSHKEY="push-check-fake-pushkey-${EPOCH}"
NOTIFY_BODY=$(python3 -c "
import json, sys
app_id, pushkey, epoch = sys.argv[1], sys.argv[2], int(sys.argv[3])
print(json.dumps({
    'notification': {
        'id': f'push-check-{epoch}',
        'room_id': '!push-check-fake-room:localhost',
        'type': 'm.room.message',
        'sender': '@rumi:localhost',
        'counts': {'unread': 1},
        'prio': 'high',
        'devices': [
            {
                'app_id': app_id,
                'pushkey': pushkey,
                'pushkey_ts': epoch,
                'data': {},
            }
        ],
    }
}))
" "${PUSH_APP_ID}" "${FAKE_PUSHKEY}" "${EPOCH}")

NOTIFY_RESP="$(curl -s -w '\n%{http_code}' -X POST "${SYGNAL_URL}/_matrix/push/v1/notify" \
  -H "Content-Type: application/json" -d "${NOTIFY_BODY}" 2>/dev/null || true)"
NOTIFY_HTTP="${NOTIFY_RESP##*$'\n'}"
NOTIFY_JSON="${NOTIFY_RESP%$'\n'*}"

if [[ "${NOTIFY_HTTP}" != "200" ]]; then
  # 502 = NotificationDispatchException (a configured pushkin tried to reach FCM/APNs and
  # failed cleanly); 500 = an uncaught Sygnal-side exception -- VERIFIED LIVE, 2026-09-23, this
  # is what a real-shaped-but-fake service account actually produces: gcmpushkin.py's OAuth
  # token refresh raises google.auth.exceptions.RefreshError ("invalid_grant: Invalid grant:
  # account not found"), which isn't wrapped as NotificationDispatchException, so Sygnal's
  # generic exception handler returns 500 with an empty body (the real error only appears in
  # `docker logs`, not the HTTP response -- see docs/PUSH.md's live-verification section for the
  # exact traceback). Either code means the same thing here: gateway reachable, a pushkin IS
  # configured for this app id, but it failed talking to the real provider -- i.e. invalid
  # credentials, not merely absent ones. Anything else (4xx) = malformed request on our side.
  check "POST /_matrix/push/v1/notify for app_id='${PUSH_APP_ID}' (gateway parses + dispatches)" 0 \
    "http_code='${NOTIFY_HTTP}' body='${NOTIFY_JSON}' -- gateway reachable but returned an error; if a pushkin IS configured for this app id, this likely means its FCM/APNs credentials are invalid, not merely absent"
else
  REJECTED=0
  [[ "$(json_list_contains "${NOTIFY_JSON}" rejected "${FAKE_PUSHKEY}")" == "1" ]] && REJECTED=1
  check "POST /_matrix/push/v1/notify for app_id='${PUSH_APP_ID}' (gateway reachable, parsed a well-formed request)" 1 ""
  if [[ "${REJECTED}" == "1" ]]; then
    echo "INFO: pushkey rejected -- app_id '${PUSH_APP_ID}' has no working pushkin configured on this Sygnal (credentials missing, not a gateway fault). See docs/PUSH.md."
  else
    echo "INFO: pushkey NOT rejected -- a pushkin for '${PUSH_APP_ID}' accepted the notification for delivery. This does NOT prove a real device received anything (a synthetic pushkey rarely gets a same-request rejection even against real credentials); only a real phone in docs/PUSH.md's manual step proves delivery."
  fi
fi

echo
echo "================================================================"
echo " push-check summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
exit 0
