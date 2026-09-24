#!/usr/bin/env bash
# Rumi Messenger -- production-hardening checks (issue #6). Asserts the safety posture a real
# domain deployment needs against a RUNNING stack: TLS + well-known actually serving, registration
# closed, Postgres/Synapse/Element not directly exposed, coturn hardening applied. Exits non-zero
# if any check fails. Same PASS/FAIL-per-check style as scripts/e2e.sh.
#
# By design, several checks only make sense (and only PASS) once the `prod`/`tls` Caddy profile is
# up against a real or `CADDY_TLS_MODE=internal` domain -- they correctly FAIL against the plain
# dev stack (no Caddy, no TLS). That is the falsifiable proof this
# script does something real, not a script that always prints PASS.
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
ELEMENT_DOMAIN="${ELEMENT_DOMAIN:-${PUBLIC_DOMAIN}}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
SYNAPSE_PORT="${SYNAPSE_PORT:-8008}"
ELEMENT_PORT="${ELEMENT_PORT:-8082}"
RUMI_CONTAINER_PREFIX="${RUMI_CONTAINER_PREFIX:-rumi}"
REGISTRATION_MODE="${REGISTRATION_MODE:-token}"
# --resolve target for curl when PUBLIC_DOMAIN/ELEMENT_DOMAIN have no real DNS yet (local proof
# with CADDY_TLS_MODE=internal) -- default 127.0.0.1, override for a real box mid-cutover.
PROD_CHECK_RESOLVE_IP="${PROD_CHECK_RESOLVE_IP:-127.0.0.1}"

PASS_COUNT=0
FAIL_COUNT=0

check() {
  local desc="$1" ok="$2" detail="${3:-}"
  if [[ "${ok}" == "1" ]]; then
    echo "PASS: ${desc}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: ${desc}${detail:+ -- ${detail}}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

curl_resolve() {
  # curl against a domain with no real DNS by pinning it to PROD_CHECK_RESOLVE_IP -- exactly the
  # `--resolve` trick used to prove this locally before a real domain exists.
  local host="$1"; shift
  curl "$@" --resolve "${host}:443:${PROD_CHECK_RESOLVE_IP}" --resolve "${host}:80:${PROD_CHECK_RESOLVE_IP}"
}

echo "== TLS / reverse proxy (Caddy, profile prod/tls) =="

WELLKNOWN_SERVER="$(curl_resolve "${PUBLIC_DOMAIN}" -sk --max-time 5 "https://${PUBLIC_DOMAIN}/.well-known/matrix/server" 2>/dev/null || true)"
check "https://\$PUBLIC_DOMAIN/.well-known/matrix/server is served over TLS" \
  "$([[ "${WELLKNOWN_SERVER}" == *"m.server"* ]] && echo 1 || echo 0)" \
  "got: ${WELLKNOWN_SERVER:-<no response -- Caddy not running / profile not up>}"

WELLKNOWN_CLIENT="$(curl_resolve "${ELEMENT_DOMAIN}" -sk --max-time 5 "https://${ELEMENT_DOMAIN}/.well-known/matrix/client" 2>/dev/null || true)"
check "https://\$ELEMENT_DOMAIN/.well-known/matrix/client is served over TLS" \
  "$([[ "${WELLKNOWN_CLIENT}" == *"m.homeserver"* ]] && echo 1 || echo 0)" \
  "got: ${WELLKNOWN_CLIENT:-<no response>}"

# A real cert vs. a plaintext/refused connection: -k accepts self-signed (CADDY_TLS_MODE=internal
# proof) or a real Let's Encrypt cert equally -- what this proves is "TLS handshake succeeds",
# not "cert is publicly trusted" (that needs a real domain + ACME, which this script can't fake).
TLS_HANDSHAKE_OK="$(curl_resolve "${PUBLIC_DOMAIN}" -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${PUBLIC_DOMAIN}/" 2>/dev/null)"
TLS_HANDSHAKE_OK="${TLS_HANDSHAKE_OK:-000}"
check "TLS handshake succeeds against \$PUBLIC_DOMAIN (any cert, incl. self-signed)" \
  "$([[ "${TLS_HANDSHAKE_OK}" != "000" ]] && echo 1 || echo 0)" \
  "http_code=${TLS_HANDSHAKE_OK}"

echo
echo "== Registration =="

REGISTER_RESP="$(curl -sk --max-time 5 -X POST "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/register" \
  -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
REGISTRATION_CLOSED=0
if echo "${REGISTER_RESP}" | grep -q "m.login.registration_token"; then
  REGISTRATION_CLOSED=1
  REG_DETAIL="live register flow requires m.login.registration_token"
elif echo "${REGISTER_RESP}" | grep -qi "registration.*disabled\|M_FORBIDDEN"; then
  REGISTRATION_CLOSED=1
  REG_DETAIL="live register endpoint refuses (disabled)"
else
  REG_DETAIL="deploy/.env REGISTRATION_MODE=${REGISTRATION_MODE}, live register flow: ${REGISTER_RESP:0:120}"
fi
check "registration is closed to the public (REGISTRATION_MODE=token, or disabled)" "${REGISTRATION_CLOSED}" "${REG_DETAIL}"

echo
echo "== Network exposure =="

# Postgres must NEVER be published to the host, in any profile -- it has no auth story here
# beyond "only reachable from the docker network", by design (no `ports:` in docker-compose.yml).
PG_PORT="$(docker port "${RUMI_CONTAINER_PREFIX}-postgres" 5432 2>/dev/null || true)"
check "postgres has no published host port" "$([[ -z "${PG_PORT}" ]] && echo 1 || echo 0)" "docker port reported: ${PG_PORT:-<none>}"

# Synapse/Element should stay on BIND_ADDR=127.0.0.1 even in prod -- Caddy reaches them over the
# docker network by service name, not via the host-published port (see deploy/.env.example).
SYNAPSE_BIND="$(docker port "${RUMI_CONTAINER_PREFIX}-synapse" 8008 2>/dev/null || true)"
check "synapse's published port is loopback-only (127.0.0.1), not 0.0.0.0" \
  "$([[ "${SYNAPSE_BIND}" == 127.0.0.1:* ]] && echo 1 || echo 0)" "docker port reported: ${SYNAPSE_BIND:-<none>}"

ELEMENT_BIND="$(docker port "${RUMI_CONTAINER_PREFIX}-element" 80 2>/dev/null || true)"
check "element's published port is loopback-only (127.0.0.1), not 0.0.0.0" \
  "$([[ "${ELEMENT_BIND}" == 127.0.0.1:* ]] && echo 1 || echo 0)" "docker port reported: ${ELEMENT_BIND:-<none>}"

# Caddy is the one thing that SHOULD be reachable from every interface once the prod/tls profile
# is up -- check the inverse of the two above.
CADDY_BIND_443="$(docker port "${RUMI_CONTAINER_PREFIX}-caddy" 443 2>/dev/null || true)"
check "caddy (443) is up and published on all interfaces (prod/tls profile only)" \
  "$(echo "${CADDY_BIND_443}" | grep -q '^0\.0\.0\.0:443$' && echo 1 || echo 0)" \
  "docker port reported: ${CADDY_BIND_443:-<not running -- expected on the plain dev stack>}"

echo
echo "== coturn hardening =="

COTURN_CONF="${DEPLOY_DIR}/coturn/turnserver.conf"
# Rendered file is chmod 600 owned by coturn's runtime uid (65534, see scripts/setup.sh) -- not
# host-readable by design, same as homeserver.yaml below. Read it via `docker exec` into the
# coturn container itself, which owns it.
COTURN_CONTENT="$(docker exec "${RUMI_CONTAINER_PREFIX}-coturn" cat /etc/coturn/turnserver.conf 2>/dev/null || true)"
if [[ -n "${COTURN_CONTENT}" ]]; then
  check "coturn: no-tcp-relay set" "$(echo "${COTURN_CONTENT}" | grep -qx 'no-tcp-relay' && echo 1 || echo 0)"
  if [[ "${BIND_ADDR}" != "127.0.0.1" ]]; then
    check "coturn: denied-peer-ip set for private ranges (BIND_ADDR is public)" \
      "$(echo "${COTURN_CONTENT}" | grep -q '^denied-peer-ip=' && echo 1 || echo 0)"
  else
    echo "SKIP: coturn denied-peer-ip check (BIND_ADDR=127.0.0.1, local-only -- see turnserver.conf's own comment)"
  fi
elif [[ -f "${COTURN_CONF}" ]]; then
  check "coturn: turnserver.conf readable" 0 "container ${RUMI_CONTAINER_PREFIX}-coturn not running -- run scripts/setup.sh / docker compose up"
else
  check "coturn: turnserver.conf exists" 0 "not found -- run scripts/setup.sh first"
fi

echo
echo "== enable_metrics =="
# homeserver.yaml is chmod 600 owned by uid 991 (synapse's runtime uid) -- read via `docker exec`
# into the synapse container itself, same reasoning as coturn above.
HS_CONTENT="$(docker exec "${RUMI_CONTAINER_PREFIX}-synapse" cat /data/homeserver.yaml 2>/dev/null || true)"
if [[ -n "${HS_CONTENT}" ]]; then
  check "enable_metrics is off (not set) in homeserver.yaml" \
    "$(echo "${HS_CONTENT}" | grep -q '^enable_metrics: *[Tt]rue' && echo 0 || echo 1)"
else
  check "homeserver.yaml readable" 0 "container ${RUMI_CONTAINER_PREFIX}-synapse not running -- run scripts/setup.sh first"
fi

echo
echo "== .env hygiene =="
check "deploy/.env is gitignored" "$(git -C "${REPO_ROOT}" check-ignore -q deploy/.env && echo 1 || echo 0)"

echo
echo "================================================================"
echo " ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
