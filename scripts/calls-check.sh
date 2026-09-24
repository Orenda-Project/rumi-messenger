#!/usr/bin/env bash
# Rumi Messenger -- group calls / screen sharing health check (issue #2).
# Falsifiable: with the "calls" profile down, every check below FAILs instead of silently
# skipping -- this script does not special-case "not running" as a pass. Requires: bash, curl,
# python3, docker. Run scripts/setup.sh first (it renders deploy/livekit/livekit.yaml even when
# the "calls" profile is not up). Needs no Caddy on the dev stack.
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
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-${SERVER_NAME}}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
ELEMENT_PORT="${ELEMENT_PORT:-8082}"
LIVEKIT_PORT="${LIVEKIT_PORT:-7880}"
LIVEKIT_JWT_PORT="${LIVEKIT_JWT_PORT:-8180}"
ELEMENT_URL="http://${BIND_ADDR}:${ELEMENT_PORT}"
RUMI_CONTAINER_PREFIX="${RUMI_CONTAINER_PREFIX:-rumi}"

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

json_field() {
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

# ---------------------------------------------------------------------------
# 1. Container liveness (docker inspect, not a Docker HEALTHCHECK for lk-jwt-service -- that
#    image is a single static, shell-less binary; see docker-compose.yml's comment).
# ---------------------------------------------------------------------------
container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]] && echo 1 || echo 0
}
LIVEKIT_UP="$(container_running "${RUMI_CONTAINER_PREFIX}-livekit")"
check "livekit container is running (scripts/setup.sh starts it unless CALLS=off)" "${LIVEKIT_UP}" \
  "container ${RUMI_CONTAINER_PREFIX}-livekit not found or not running"
JWT_UP="$(container_running "${RUMI_CONTAINER_PREFIX}-lk-jwt-service")"
check "lk-jwt-service container is running" "${JWT_UP}" \
  "container ${RUMI_CONTAINER_PREFIX}-lk-jwt-service not found or not running"
PROXY_UP="$(container_running "${RUMI_CONTAINER_PREFIX}-calls-proxy")"
check "calls-proxy container is running (lk-jwt-service's network namespace)" "${PROXY_UP}" \
  "container ${RUMI_CONTAINER_PREFIX}-calls-proxy not found or not running"

# ---------------------------------------------------------------------------
# 2. LiveKit SFU answers on its signalling port.
# ---------------------------------------------------------------------------
LIVEKIT_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${BIND_ADDR}:${LIVEKIT_PORT}/" 2>/dev/null || echo 000)"
LIVEKIT_OK=0; [[ "${LIVEKIT_CODE}" == "200" ]] && LIVEKIT_OK=1
check "LiveKit SFU answers on :${LIVEKIT_PORT}" "${LIVEKIT_OK}" "GET / returned HTTP ${LIVEKIT_CODE}"

# ---------------------------------------------------------------------------
# 3. lk-jwt-service answers its (undocumented-but-real, verified live) /healthz route --
#    /health (singular, what the upstream README's Docker example implies) 404s.
# ---------------------------------------------------------------------------
JWT_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${BIND_ADDR}:${LIVEKIT_JWT_PORT}/healthz" 2>/dev/null || echo 000)"
JWT_OK=0; [[ "${JWT_CODE}" == "200" ]] && JWT_OK=1
check "lk-jwt-service answers on :${LIVEKIT_JWT_PORT}/healthz" "${JWT_OK}" "GET /healthz returned HTTP ${JWT_CODE}"

# ---------------------------------------------------------------------------
# 4. Element config.json carries the group-calls feature flags (issue #2's own client-side
#    switch) -- independent of whether the "calls" profile is up, since this is Element's static
#    config, but a real falsifiable check: flip feature_group_calls off in
#    config.template.json and this FAILs.
# ---------------------------------------------------------------------------
CONFIG_JSON="$(curl -fsS "${ELEMENT_URL}/config.json" 2>/dev/null || true)"
GROUP_CALLS_FLAG="$(python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    d={}
print(d.get('features',{}).get('feature_group_calls'))
" "${CONFIG_JSON}" 2>/dev/null)"
GROUP_CALLS_OK=0; [[ "${GROUP_CALLS_FLAG}" == "True" ]] && GROUP_CALLS_OK=1
check "Element config.json features.feature_group_calls == true" "${GROUP_CALLS_OK}" "got '${GROUP_CALLS_FLAG}'"

# ---------------------------------------------------------------------------
# 5-8. What CLIENTS are told, and that it actually works. Synapse's MSC4143 /rtc/transports is the
#      one discovery path both apps read (setup.sh writes it only when it started the calls
#      services). The URL must not be a Docker-internal name (a phone cannot resolve
#      "lk-jwt-service"), it must ANSWER, and a real OpenID token must get a LiveKit JWT from it --
#      the exact step that failed as OPEN_ID_ERROR / "Failed to authenticate to transport".
# ---------------------------------------------------------------------------
SYNAPSE_URL="http://${BIND_ADDR}:${SYNAPSE_PORT:-8008}"
is_public_url() {  # prints 1 if $1 is a non-empty http(s)/ws(s) URL with no docker-internal host
  python3 -c "
import sys, urllib.parse
u = sys.argv[1]
h = (urllib.parse.urlsplit(u).hostname or '') if u else ''
internal = {'lk-jwt-service', 'livekit', 'synapse', 'caddy', 'element', 'calls-proxy', ''}
print(1 if u and h not in internal and not h.startswith('rumi-') else 0)
" "$1" 2>/dev/null
}
ADMIN_TOKEN="$(curl -s -X POST "${SYNAPSE_URL}/_matrix/client/v3/login" -H 'Content-Type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${ADMIN_USER:-admin}\"},\"password\":\"${ADMIN_PASSWORD:-}\"}" 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)"
TRANSPORTS_JSON=""; OPENID_JSON=""
if [[ -n "${ADMIN_TOKEN}" ]]; then
  TRANSPORTS_JSON="$(curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${SYNAPSE_URL}/_matrix/client/unstable/org.matrix.msc4143/rtc/transports" 2>/dev/null || true)"
  OPENID_JSON="$(curl -s -X POST -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' -d '{}' \
    "${SYNAPSE_URL}/_matrix/client/v3/user/%40${ADMIN_USER:-admin}%3A${SERVER_NAME}/openid/request_token" 2>/dev/null || true)"
  # Log the check's own session out again so repeated runs don't pile up admin devices.
  curl -s -o /dev/null -X POST -H "Authorization: Bearer ${ADMIN_TOKEN}" "${SYNAPSE_URL}/_matrix/client/v3/logout" 2>/dev/null || true
fi
TRANSPORT_URL="$(python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    d={}
t=[x for x in d.get('rtc_transports',[]) if x.get('type')=='livekit']
print(t[0].get('livekit_service_url','') if t else '')
" "${TRANSPORTS_JSON}" 2>/dev/null)"
check "Synapse MSC4143 /rtc/transports gives clients a PUBLIC livekit_service_url" "$(is_public_url "${TRANSPORT_URL}")" \
  "got '${TRANSPORT_URL:-<none>}' (raw: ${TRANSPORTS_JSON:0:160}) -- re-run scripts/setup.sh (CALLS=off advertises nothing)"

# CALLS_CHECK_RESOLVE=<domain>:443:127.0.0.1 lets a local test domain with no DNS be checked.
RESOLVE_ARGS=(); [[ -n "${CALLS_CHECK_RESOLVE:-}" ]] && RESOLVE_ARGS=(--resolve "${CALLS_CHECK_RESOLVE}")
HZ_CODE="000"
[[ -n "${TRANSPORT_URL}" ]] && HZ_CODE="$(curl -sk "${RESOLVE_ARGS[@]}" -o /dev/null -w '%{http_code}' --max-time 5 "${TRANSPORT_URL%/}/healthz" 2>/dev/null || true)"
HZ_OK=0; [[ "${HZ_CODE}" == "200" ]] && HZ_OK=1
check "the advertised transport URL answers from this host (${TRANSPORT_URL:-<none>}/healthz)" "${HZ_OK}" "HTTP ${HZ_CODE} -- clients are being sent to a dead address"

SFU_JSON=""
if [[ -n "${TRANSPORT_URL}" && -n "${OPENID_JSON}" ]]; then
  SFU_BODY="$(python3 -c "
import json,sys
o=json.loads(sys.argv[1])
print(json.dumps({'room':'!calls-check:'+sys.argv[2],'device_id':'CALLSCHECK','openid_token':o}))
" "${OPENID_JSON}" "${SERVER_NAME}" 2>/dev/null)"
  SFU_JSON="$(curl -sk "${RESOLVE_ARGS[@]}" --max-time 40 -X POST -H 'Content-Type: application/json' -d "${SFU_BODY}" "${TRANSPORT_URL%/}/sfu/get" 2>/dev/null || true)"
fi
SFU_JWT="$(json_field "${SFU_JSON}" jwt)"
WS_URL="$(json_field "${SFU_JSON}" url)"
check "a real OpenID token gets a LiveKit JWT from the advertised transport (no OPEN_ID_ERROR)" "$([[ -n "${SFU_JWT}" ]] && echo 1 || echo 0)" \
  "POST ${TRANSPORT_URL:-<none>}/sfu/get -> ${SFU_JSON:0:200}"
check "lk-jwt-service hands clients a PUBLIC LiveKit ws(s):// URL" "$(is_public_url "${WS_URL}")" "got '${WS_URL:-<none>}'"

# ---------------------------------------------------------------------------
# 9. Members may JOIN a call: new rooms get org.matrix.msc3401.call.member at power level 0.
#    Without it a non-admin teacher's join is 403'd and Element Call drops them ("Connection
#    lost") -- the root cause of round 1's second-participant abort.
# ---------------------------------------------------------------------------
PL_MEMBER="$(docker exec "${RUMI_CONTAINER_PREFIX}-synapse" python3 -c "
import yaml
c=yaml.safe_load(open('/data/homeserver.yaml'))
print(c.get('default_power_level_content_override',{}).get('private_chat',{}).get('events',{}).get('org.matrix.msc3401.call.member','unset'))
" 2>/dev/null)"
PL_OK=0; [[ "${PL_MEMBER}" == "0" ]] && PL_OK=1
check "new rooms let members join calls (call.member power level 0)" "${PL_OK}" "got '${PL_MEMBER:-unreadable}' -- re-run scripts/setup.sh"

# ---------------------------------------------------------------------------
# 10. Delayed events (MSC4140) on, so a crashed phone's call membership expires instead of
#     leaving a "Waiting for media..." ghost tile for hours.
# ---------------------------------------------------------------------------
DELAYED="$(curl -s "${SYNAPSE_URL}/_matrix/client/versions" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("unstable_features",{}).get("org.matrix.msc4140"))' 2>/dev/null)"
DELAYED_OK=0; [[ "${DELAYED}" == "True" ]] && DELAYED_OK=1
check "Synapse advertises delayed events (org.matrix.msc4140)" "${DELAYED_OK}" "got '${DELAYED}'"

echo
echo "================================================================"
echo " calls-check summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
exit 0
