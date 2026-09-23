#!/usr/bin/env bash
# Rumi Messenger -- one-command setup. Idempotent: safe to re-run any time.
#
# Requires only: docker (with the compose plugin), curl, python3, openssl.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (works from any cwd)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"
ENV_EXAMPLE="${DEPLOY_DIR}/.env.example"
SYNAPSE_DATA_DIR="${DEPLOY_DIR}/synapse/data"
ELEMENT_DIR="${DEPLOY_DIR}/element"
CHANNEL_ENV_FILE="${DEPLOY_DIR}/rumi-channel.env"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

dc() {
  (cd "${DEPLOY_DIR}" && docker compose "$@")
}

rand_secret() {
  openssl rand -hex 24
}

fill_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

# Vars a caller can reasonably override by exporting before running this script (e.g.
# `SYNAPSE_PORT=8208 ELEMENT_PORT=8283 scripts/setup.sh`). These must win over both a freshly
# copied .env.example AND an existing deploy/.env -- otherwise `source`-ing the file below would
# silently clobber the caller's exported values back to whatever the file says.
OVERRIDE_VARS=(SERVER_NAME PUBLIC_BASE_URL SYNAPSE_PORT ELEMENT_PORT BIND_ADDR REGISTRATION_MODE COMPOSE_PROJECT_NAME RUMI_CONTAINER_PREFIX TURN_PORT TURN_MIN_PORT TURN_MAX_PORT)
for _v in "${OVERRIDE_VARS[@]}"; do
  eval "PRESET_${_v}=\"\${${_v}:-}\""
done

# ---------------------------------------------------------------------------
# Step 1: .env
# ---------------------------------------------------------------------------
log "Step 1/10: ensuring deploy/.env exists"
if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  log "  created deploy/.env from .env.example"
  # Bake any pre-exported overrides straight into the fresh file so they're not silently
  # ignored on the very first run.
  for _v in "${OVERRIDE_VARS[@]}"; do
    eval "_val=\"\${PRESET_${_v}}\""
    if [[ -n "${_val}" ]]; then
      fill_env_var "${_v}" "${_val}"
      log "  applied exported override ${_v}=${_val}"
    fi
  done
fi
chmod 600 "${ENV_FILE}"

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

# Exported overrides always win, even against an EXISTING .env file that already has a
# different value on disk (a rerun with a different SYNAPSE_PORT exported should rebind, not
# silently keep whatever the file said). `export` (not a plain assignment) matters here: the
# docker-compose.yml interpolation and every `dc ...` subprocess below need it in their
# environment, not just this script's local variable.
for _v in "${OVERRIDE_VARS[@]}"; do
  eval "_val=\"\${PRESET_${_v}}\""
  if [[ -n "${_val}" ]]; then
    export "${_v}=${_val}"
  fi
done

GENERATED_ADMIN_PASSWORD=""
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  POSTGRES_PASSWORD="$(rand_secret)"
  fill_env_var POSTGRES_PASSWORD "${POSTGRES_PASSWORD}"
  log "  generated POSTGRES_PASSWORD"
fi
if [[ -z "${RUMI_BOT_PASSWORD:-}" ]]; then
  RUMI_BOT_PASSWORD="$(rand_secret)"
  fill_env_var RUMI_BOT_PASSWORD "${RUMI_BOT_PASSWORD}"
  log "  generated RUMI_BOT_PASSWORD"
fi
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  ADMIN_PASSWORD="$(rand_secret)"
  fill_env_var ADMIN_PASSWORD "${ADMIN_PASSWORD}"
  GENERATED_ADMIN_PASSWORD="${ADMIN_PASSWORD}"
  log "  generated ADMIN_PASSWORD"
fi
if [[ -z "${REG_SHARED_SECRET:-}" ]]; then
  REG_SHARED_SECRET="$(rand_secret)"
  fill_env_var REG_SHARED_SECRET "${REG_SHARED_SECRET}"
  log "  generated REG_SHARED_SECRET (registration_shared_secret)"
fi
if [[ -z "${TURN_SHARED_SECRET:-}" ]]; then
  TURN_SHARED_SECRET="$(rand_secret)"
  fill_env_var TURN_SHARED_SECRET "${TURN_SHARED_SECRET}"
  log "  generated TURN_SHARED_SECRET (coturn static-auth-secret / Synapse turn_shared_secret)"
fi

SERVER_NAME="${SERVER_NAME:-localhost}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://localhost:8008}"
SYNAPSE_PORT="${SYNAPSE_PORT:-8008}"
ELEMENT_PORT="${ELEMENT_PORT:-8082}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
ADMIN_USER="${ADMIN_USER:-admin}"
REGISTRATION_MODE="${REGISTRATION_MODE:-open}"
TURN_PORT="${TURN_PORT:-3478}"
TURN_MIN_PORT="${TURN_MIN_PORT:-49152}"
TURN_MAX_PORT="${TURN_MAX_PORT:-65535}"
# The address Matrix clients (Element Web running in a teacher's browser) are told to open a
# TURN connection to -- must be something those clients can actually reach, same requirement as
# PUBLIC_BASE_URL itself, so we derive it from the same setting rather than inventing a second
# one: the hostname half of PUBLIC_BASE_URL (e.g. "localhost", or "chat.yourschool.org" in
# production).
TURN_HOST="$(python3 -c "
import sys, urllib.parse
print(urllib.parse.urlsplit(sys.argv[1]).hostname or 'localhost')
" "${PUBLIC_BASE_URL}")"

# ---------------------------------------------------------------------------
# Step 2: generate homeserver.yaml if absent
# ---------------------------------------------------------------------------
log "Step 2/10: Synapse homeserver.yaml"
mkdir -p "${SYNAPSE_DATA_DIR}"
if [[ ! -f "${SYNAPSE_DATA_DIR}/homeserver.yaml" ]]; then
  log "  homeserver.yaml missing -> generating"
  dc run --rm -e SYNAPSE_SERVER_NAME="${SERVER_NAME}" -e SYNAPSE_REPORT_STATS=no synapse generate
else
  log "  homeserver.yaml already present, skipping generate"
fi

# ---------------------------------------------------------------------------
# Step 3: patch homeserver.yaml (via the synapse image's own python3+PyYAML)
# ---------------------------------------------------------------------------
log "Step 3/10: patching homeserver.yaml (db, registration, auto-join, uploads, presence)"
dc run --rm \
  -e SERVER_NAME="${SERVER_NAME}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  -e REGISTRATION_MODE="${REGISTRATION_MODE}" \
  -e REG_SHARED_SECRET="${REG_SHARED_SECRET}" \
  -e TURN_HOST="${TURN_HOST}" \
  -e TURN_PORT="${TURN_PORT}" \
  -e TURN_SHARED_SECRET="${TURN_SHARED_SECRET}" \
  --entrypoint python3 synapse - <<'PYEOF'
import os, yaml

path = "/data/homeserver.yaml"
with open(path) as f:
    config = yaml.safe_load(f)

server_name = os.environ["SERVER_NAME"]
mode = os.environ["REGISTRATION_MODE"]

config["database"] = {
    "name": "psycopg2",
    "args": {
        "user": "synapse",
        "password": os.environ["POSTGRES_PASSWORD"],
        "database": "synapse",
        "host": "postgres",
        "port": 5432,
        "cp_min": 5,
        "cp_max": 10,
    },
}

if mode == "token":
    config["enable_registration"] = True
    config["registration_requires_token"] = True
    config.pop("enable_registration_without_verification", None)
else:
    config["enable_registration"] = True
    config["enable_registration_without_verification"] = True
    config["registration_requires_token"] = False

config["registration_shared_secret"] = os.environ["REG_SHARED_SECRET"]
config["auto_join_rooms"] = [f"#rumi-announcements:{server_name}"]
config["autocreate_auto_join_rooms"] = True
config["max_upload_size"] = "50M"
config["url_preview_enabled"] = False
config["presence"] = {"enabled": True}
config["report_stats"] = False

# Synapse's default rate limits assume a public server defending itself. A school is
# the opposite shape: a staffroom signs in together at 8am and a class joins a room
# together, which at the defaults reads as abuse and answers M_LIMIT_EXCEEDED.
config["rc_login"] = {
    "address": {"per_second": 1, "burst_count": 30},
    "account": {"per_second": 1, "burst_count": 30},
    "failed_attempts": {"per_second": 0.5, "burst_count": 10},
}
config["rc_joins"] = {
    "local": {"per_second": 1, "burst_count": 50},
    "remote": {"per_second": 0.05, "burst_count": 10},
}
config["rc_message"] = {"per_second": 5, "burst_count": 30}
config["rc_invites"] = {
    "per_room": {"per_second": 1, "burst_count": 20},
    "per_user": {"per_second": 1, "burst_count": 20},
}

# TURN server for 1:1 audio/video calls (issue #1). turn_shared_secret must be the exact same
# string as coturn's own static-auth-secret (deploy/coturn/turnserver.conf, written by step 5
# below) -- Synapse's TURN REST API implementation mints a short-lived username/password pair
# per client ("<unix-ts>+<user id>", HMAC-SHA1 of that over the shared secret, base64), and
# coturn validates that same construction on connect (use-auth-secret mode). Two URIs, UDP and
# TCP, per Matrix's own coturn guide (element-hq/synapse docs/setup/turn/coturn.md) -- clients
# try UDP first and fall back to TCP when UDP is blocked by a restrictive firewall.
config["turn_uris"] = [
    f"turn:{os.environ['TURN_HOST']}:{os.environ['TURN_PORT']}?transport=udp",
    f"turn:{os.environ['TURN_HOST']}:{os.environ['TURN_PORT']}?transport=tcp",
]
config["turn_shared_secret"] = os.environ["TURN_SHARED_SECRET"]
# 24h, the same value Synapse's own docs use as their example -- credentials are per-call-session
# scoped by the client anyway (a fresh set is fetched per call), this just bounds how long a
# leaked credential would remain valid.
config["turn_user_lifetime"] = 86400000
config["turn_allow_guests"] = True

with open(path, "w") as f:
    yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)

print("homeserver.yaml patched")
PYEOF

# homeserver.yaml (registration_shared_secret, macaroon_secret_key, form_secret) and the
# signing key are secrets. /data is owned by uid/gid 991 inside the container, so chmod them
# from inside the image (root by default for `run`) rather than the host user.
dc run --rm --entrypoint sh synapse -c "chmod 600 /data/homeserver.yaml /data/${SERVER_NAME}.signing.key"
log "  chmod 600 on homeserver.yaml + signing key"

# ---------------------------------------------------------------------------
# Step 4: log config -> JSON lines to stdout (docker logs IS the log)
# ---------------------------------------------------------------------------
log "Step 4/10: switching Synapse log config to JSON-on-stdout"
LOG_CONFIG_NAME="${SERVER_NAME}.log.config"
# The synapse image ships neither python-json-logger nor a synapse.logging.formatter.JsonFormatter,
# so we drop in a tiny stdlib-only formatter module and put /data on PYTHONPATH (see
# docker-compose.yml) so dictConfig can import it by name.
# /data ends up owned by uid/gid 991 (the synapse container's runtime user) after `generate`,
# so write+chown from inside the image (which runs `run`/`exec` as root) rather than from the
# host user.
dc run --rm --entrypoint sh synapse -c "cat > /data/rumi_log_format.py <<'PYEOF'
import json
import logging


class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            'timestamp': self.formatTime(record, '%Y-%m-%dT%H:%M:%S%z'),
            'level': record.levelname,
            'logger': record.name,
            'message': record.getMessage(),
        }
        if record.exc_info:
            payload['exc_info'] = self.formatException(record.exc_info)
        return json.dumps(payload)
PYEOF
cat > /data/${LOG_CONFIG_NAME} <<'LOGEOF'
version: 1
formatters:
  json:
    class: rumi_log_format.JsonFormatter
handlers:
  stdout:
    class: logging.StreamHandler
    formatter: json
    stream: ext://sys.stdout
loggers:
  synapse.storage.SQL:
    level: INFO
root:
  level: INFO
  handlers: [stdout]
disable_existing_loggers: false
LOGEOF
chown 991:991 /data/rumi_log_format.py /data/${LOG_CONFIG_NAME}"
log "  wrote ${SYNAPSE_DATA_DIR}/${LOG_CONFIG_NAME} + rumi_log_format.py"

# ---------------------------------------------------------------------------
# Step 5: coturn TURN relay config (1:1 audio/video calls, issue #1)
# ---------------------------------------------------------------------------
log "Step 5/10: coturn TURN relay config"
COTURN_DIR="${DEPLOY_DIR}/coturn"
mkdir -p "${COTURN_DIR}"
# A prior run chown'd this to coturn's runtime uid (65534, see below) and chmod 600'd it, which
# this host user can't truncate/overwrite directly on a rerun -- but CAN unlink (removing a file
# only needs write+execute on the containing directory, which this host user owns), so drop it
# and re-render fresh every time, same idempotency shape as Element's rendered config/welcome/home.
rm -f "${COTURN_DIR}/turnserver.conf"
{
  echo "# Rendered by scripts/setup.sh -- edit deploy/.env, not this file, then re-run setup.sh."
  echo "listening-port=${TURN_PORT}"
  echo "min-port=${TURN_MIN_PORT}"
  echo "max-port=${TURN_MAX_PORT}"
  # Keeps coturn off-network by default the same way BIND_ADDR keeps every other service here
  # off-network -- network_mode: host means Compose's own ports:/BIND_ADDR binding (what Synapse
  # and Element rely on) doesn't apply to this container, so this config line is what actually
  # does it. 127.0.0.1 (the default) => loopback-only, exactly like the rest of the stack before
  # the `tls` profile is turned on; 0.0.0.0 => every interface, once BIND_ADDR is set that way for
  # a real deployment (docs/RUNBOOK.md).
  echo "listening-ip=${BIND_ADDR}"
  # TURN REST API short-lived credentials -- see the homeserver.yaml turn_shared_secret comment
  # in step 3 above for the full mechanism. static-auth-secret here MUST equal turn_shared_secret
  # there; both come from the one TURN_SHARED_SECRET value in deploy/.env.
  echo "use-auth-secret"
  echo "static-auth-secret=${TURN_SHARED_SECRET}"
  echo "realm=${SERVER_NAME}"
  # Matrix's own coturn guide (element-hq/synapse docs/setup/turn/coturn.md) recommends this for
  # NAT traversal reliability with some client/NAT combinations.
  echo "fingerprint"
  # KNOWN GAP, not a silent omission: plaintext TURN only (no TLS/DTLS listener) at this stage.
  # Real certs are the production-hardening work already tracked in issue #6 -- Caddy (the `tls`
  # compose profile) terminates TLS for Synapse/Element, but coturn needs its OWN certificate,
  # since a browser's WebRTC stack talks to it directly rather than through Caddy. Acceptable for
  # now the same way the rest of this stack is BIND_ADDR=127.0.0.1-by-default and not yet
  # publicly reachable; not acceptable to leave silently unmentioned, so: this is unencrypted
  # until #6. See docs/RUNBOOK.md.
  #
  # Only `no-tls` is a real coturn 4.18.0 directive (disables the TLS listener). There is no
  # `no-dtls` in this version -- DTLS is opt-IN via a separate `--dtls` flag that defaults to off
  # (confirmed against this exact pinned image's own `turnserver -h`; an earlier draft of this
  # file carried a `no-dtls` line copied from older coturn docs, which 4.18.0 logs as "Bad
  # configuration format: no-dtls" and ignores -- harmless since DTLS was never on, but wrong,
  # so removed rather than left in as dead/misleading config). See docs/DECISIONS.tsv.
  echo "no-tls"
  echo "log-file=stdout"
  echo "simple-log"
  if [[ -n "${TURN_EXTERNAL_IP:-}" ]]; then
    echo "external-ip=${TURN_EXTERNAL_IP}"
  fi
} > "${COTURN_DIR}/turnserver.conf"
# turnserver.conf holds TURN_SHARED_SECRET in plaintext, same trust tier as homeserver.yaml --
# but coturn's image runs as a fixed "nobody" (uid/gid 65534), not a uid this host user can
# `chown` to directly, and the compose service mounts the file `:ro` (so a container running
# under that mount can't chown/chmod it either). Same fix as homeserver.yaml's uid-991 case:
# chown to the exact runtime uid from a throwaway container run AS ROOT against a writable
# mount of the directory (not the `:ro` service mount), then lock it down to owner-only.
COTURN_IMAGE="$(dc config --images coturn)"
docker run --rm --user root --entrypoint sh \
  -v "${COTURN_DIR}:/data" \
  "${COTURN_IMAGE}" \
  -c "chown 65534:65534 /data/turnserver.conf && chmod 600 /data/turnserver.conf"
log "  wrote deploy/coturn/turnserver.conf (listening-ip=${BIND_ADDR}, realm=${SERVER_NAME}, turn_uris host=${TURN_HOST})"

# ---------------------------------------------------------------------------
# Step 6: bring the stack up
# ---------------------------------------------------------------------------
log "Step 6/10: starting postgres + synapse + coturn"
dc up -d postgres synapse
# Restart (not recreate -- image/mounts are unchanged, only homeserver.yaml's *content* was, by
# step 3, which runs unconditionally on every invocation): Synapse reads homeserver.yaml once at
# startup, it does not hot-reload turn_uris/turn_shared_secret. On a fresh install this is a
# harmless restart of a container that just started seconds ago; on a rerun against an
# ALREADY-RUNNING stack (exactly the scenario this was found in) it's the only thing that makes
# a homeserver.yaml edit actually take effect -- discovered live: turnServer returned `{}` after
# adding turn_uris to a running Synapse's config file with no restart, RUNBOOK.md's existing
# "Rate limits" section already documents this same requirement for a *manual* edit, this just
# makes setup.sh's own automatic edits honor it too instead of silently no-op'ing on a rerun.
dc restart synapse
# --force-recreate: same reasoning as element's force-recreate in step 9 -- turnserver.conf was
# just rewritten in place (fresh secret file, same path/mount/image), and a plain `up -d` no-ops
# on a container already running with the same image+mount config even though the file's bytes
# changed underneath it, leaving a stale coturn serving whatever config existed at its first
# start. A prior run of this exact script hit precisely that: coturn kept running for 2+ minutes
# on a config it couldn't even read, discovered live while writing this script.
dc up -d --force-recreate coturn

log "  waiting for Synapse /_matrix/client/versions"
for i in $(seq 1 60); do
  if curl -fsS "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/versions" >/dev/null 2>&1; then
    log "  Synapse is up"
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    log "  ERROR: Synapse did not become ready in time"
    dc logs --tail=100 synapse || true
    exit 1
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# Step 7: admin + bot accounts
# ---------------------------------------------------------------------------
log "Step 7/10: admin + @rumi bot accounts"

register_user() {
  local username="$1" password="$2" admin_flag="$3"
  local out rc
  set +e
  out=$(dc exec -T synapse register_new_matrix_user -c /data/homeserver.yaml \
    -u "${username}" -p "${password}" ${admin_flag} --exists-ok http://localhost:8008 2>&1)
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "  ERROR creating user '${username}': ${out}"
    exit 1
  fi
  if echo "${out}" | grep -qi "already exists"; then
    log "  user '${username}' already exists, skipping create"
  else
    log "  created user '${username}'"
  fi
}

register_user "${ADMIN_USER}" "${ADMIN_PASSWORD}" "-a"
register_user "rumi" "${RUMI_BOT_PASSWORD}" "--no-admin"

# Login with retry on 429: Synapse rate-limits password logins (rc_login), and a
# rerun straight after heavy testing would otherwise abort the whole setup.
login_user() {
  local username="$1" password="$2" attempt out code
  for attempt in 1 2 3 4 5; do
    out="$(curl -sS -w '\n%{http_code}' -X POST "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/login" \
      -H "Content-Type: application/json" \
      -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${username}\"},\"password\":\"${password}\"}")"
    code="${out##*$'\n'}"; out="${out%$'\n'*}"
    if [[ "${code}" == "200" ]]; then printf '%s' "${out}"; return 0; fi
    if [[ "${code}" == "429" ]]; then
      local wait_ms; wait_ms="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('retry_after_ms',5000))" "${out}" 2>/dev/null || echo 5000)"
      log "  login rate-limited (429), retrying in $((wait_ms/1000+1))s (attempt ${attempt}/5)"
      sleep "$((wait_ms/1000+1))"; continue
    fi
    log "  ERROR: login for ${username} failed with HTTP ${code}: ${out}"; return 1
  done
  log "  ERROR: login for ${username} still rate-limited after 5 attempts"; return 1
}

BOT_USER_ID="@rumi:${SERVER_NAME}"
# Reuse the existing bot token if it still works, so reruns never touch the login endpoint.
BOT_TOKEN=""
if [[ -f "${CHANNEL_ENV_FILE}" ]]; then
  BOT_TOKEN="$(grep -E '^MATRIX_ACCESS_TOKEN=' "${CHANNEL_ENV_FILE}" | cut -d= -f2- || true)"
  if [[ -n "${BOT_TOKEN}" ]] && curl -fsS -H "Authorization: Bearer ${BOT_TOKEN}" \
       "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/account/whoami" >/dev/null 2>&1; then
    log "  existing @rumi token still valid, skipping login"
  else
    BOT_TOKEN=""
  fi
fi
if [[ -z "${BOT_TOKEN}" ]]; then
  BOT_LOGIN_JSON="$(login_user rumi "${RUMI_BOT_PASSWORD}")"
  BOT_TOKEN="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['access_token'])" "${BOT_LOGIN_JSON}")"
fi

cat > "${CHANNEL_ENV_FILE}" <<EOF
# Written by scripts/setup.sh. rumi-platform reads this to log the @rumi bot into Matrix.
MATRIX_HOMESERVER_URL=${PUBLIC_BASE_URL}
MATRIX_ACCESS_TOKEN=${BOT_TOKEN}
MATRIX_USER_ID=${BOT_USER_ID}
EOF
chmod 600 "${CHANNEL_ENV_FILE}"
log "  wrote deploy/rumi-channel.env for rumi-platform (chmod 600)"

log "  setting @rumi displayname + avatar"
curl -fsS -X PUT "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/profile/${BOT_USER_ID}/displayname" \
  -H "Authorization: Bearer ${BOT_TOKEN}" -H "Content-Type: application/json" \
  -d '{"displayname":"Rumi"}' >/dev/null

AVATAR_FILE="${ELEMENT_DIR}/assets/rumi-avatar-navy.png"
CURRENT_AVATAR="$(curl -fsS "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/profile/${BOT_USER_ID}/avatar_url" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('avatar_url') or '')" 2>/dev/null || true)"
if [[ -n "${CURRENT_AVATAR}" ]]; then
  log "  avatar already set (${CURRENT_AVATAR}), skipping upload"
elif [[ -f "${AVATAR_FILE}" ]]; then
  UPLOAD_JSON="$(curl -fsS -X POST "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/media/v3/upload?filename=rumi-avatar.png" \
    -H "Authorization: Bearer ${BOT_TOKEN}" -H "Content-Type: image/png" \
    --data-binary @"${AVATAR_FILE}")"
  MXC_URI="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['content_uri'])" "${UPLOAD_JSON}")"
  curl -fsS -X PUT "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/profile/${BOT_USER_ID}/avatar_url" \
    -H "Authorization: Bearer ${BOT_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"avatar_url\":\"${MXC_URI}\"}" >/dev/null
  log "  avatar set (${MXC_URI})"
else
  log "  WARNING: ${AVATAR_FILE} not found, skipping avatar upload"
fi

# ---------------------------------------------------------------------------
# Step 7: ensure #rumi-announcements exists
# ---------------------------------------------------------------------------
log "Step 8/10: ensuring #rumi-announcements exists"
ALIAS="%23rumi-announcements:${SERVER_NAME}"
set +e
RESOLVE_HTTP=$(curl -s -o /tmp/rumi-alias-resolve.json -w '%{http_code}' \
  "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/directory/room/${ALIAS}" \
  -H "Authorization: Bearer ${BOT_TOKEN}")
set -e
if [[ "${RESOLVE_HTTP}" == "200" ]]; then
  log "  #rumi-announcements already exists"
else
  curl -fsS -X POST "http://${BIND_ADDR}:${SYNAPSE_PORT}/_matrix/client/v3/createRoom" \
    -H "Authorization: Bearer ${BOT_TOKEN}" -H "Content-Type: application/json" \
    -d '{
      "room_alias_name": "rumi-announcements",
      "name": "Rumi Announcements",
      "topic": "Updates from Rumi and your team",
      "visibility": "public",
      "preset": "public_chat"
    }' >/dev/null
  log "  created #rumi-announcements"
fi

# ---------------------------------------------------------------------------
# Step 9: render Element config + welcome page from the branded templates
# ---------------------------------------------------------------------------
log "Step 9/10: rendering deploy/element/{config.json,welcome.html,home.html}"

# Substitutes the literal placeholders __SERVER_NAME__ / __PUBLIC_BASE_URL__ in a template file
# and writes the result. Used for both config.template.json -> config.json and
# welcome.template.html -> welcome.html so rumi-platform/Element never see raw placeholders
# (Element's HTML sanitizer blocks any client-side templating in welcome.html, so this has to
# happen at render time, not in the browser).
render_template() {
  local tpl_path="$1" out_path="$2"
  python3 - "${tpl_path}" "${out_path}" "${SERVER_NAME}" "${PUBLIC_BASE_URL}" <<'PYEOF'
import sys
tpl_path, out_path, server_name, public_base_url = sys.argv[1:5]
with open(tpl_path) as f:
    content = f.read()
content = content.replace("__SERVER_NAME__", server_name).replace("__PUBLIC_BASE_URL__", public_base_url)
with open(out_path, "w") as f:
    f.write(content)
PYEOF
}

CONFIG_TEMPLATE="${ELEMENT_DIR}/config.template.json"
CLEANUP_CONFIG_TEMPLATE=0
if [[ ! -f "${CONFIG_TEMPLATE}" ]]; then
  log "  WARNING: config.template.json missing (branding agent hasn't written it yet)"
  log "  using a throwaway minimal template for this test run only (not committed)"
  CONFIG_TEMPLATE="$(mktemp)"
  CLEANUP_CONFIG_TEMPLATE=1
  cat > "${CONFIG_TEMPLATE}" <<'TPLEOF'
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "__PUBLIC_BASE_URL__",
      "server_name": "__SERVER_NAME__"
    }
  },
  "brand": "Rumi",
  "welcome_user_id": "@rumi:__SERVER_NAME__",
  "default_theme": "light",
  "disable_custom_urls": false
}
TPLEOF
fi
render_template "${CONFIG_TEMPLATE}" "${ELEMENT_DIR}/config.json"
if [[ "${CLEANUP_CONFIG_TEMPLATE}" == "1" ]]; then
  rm -f "${CONFIG_TEMPLATE}"
fi

WELCOME_TEMPLATE="${ELEMENT_DIR}/welcome.template.html"
CLEANUP_WELCOME_TEMPLATE=0
if [[ ! -f "${WELCOME_TEMPLATE}" ]]; then
  log "  WARNING: welcome.template.html missing (branding agent hasn't written it yet)"
  log "  using a throwaway minimal template for this test run only (not committed)"
  WELCOME_TEMPLATE="$(mktemp)"
  CLEANUP_WELCOME_TEMPLATE=1
  cat > "${WELCOME_TEMPLATE}" <<'HTMLEOF'
<!DOCTYPE html>
<html><head><title>Rumi Messenger</title></head>
<body><p>Placeholder welcome page -- replaced by the branding work package.
<a href="#/user/@rumi:__SERVER_NAME__?action=chat">Talk to Rumi</a></p></body></html>
HTMLEOF
fi
render_template "${WELCOME_TEMPLATE}" "${ELEMENT_DIR}/welcome.html"
if [[ "${CLEANUP_WELCOME_TEMPLATE}" == "1" ]]; then
  rm -f "${WELCOME_TEMPLATE}"
fi

HOME_TEMPLATE="${ELEMENT_DIR}/home.template.html"
CLEANUP_HOME_TEMPLATE=0
if [[ ! -f "${HOME_TEMPLATE}" ]]; then
  log "  WARNING: home.template.html missing (branding agent hasn't written it yet)"
  log "  using a throwaway minimal template for this test run only (not committed)"
  HOME_TEMPLATE="$(mktemp)"
  CLEANUP_HOME_TEMPLATE=1
  cat > "${HOME_TEMPLATE}" <<'HOMEEOF'
<!DOCTYPE html>
<html><head><title>Rumi Messenger</title></head>
<body><p>Placeholder home page -- replaced by the branding work package.
<a href="#/user/@rumi:__SERVER_NAME__?action=chat">Talk to Rumi</a></p></body></html>
HOMEEOF
fi
render_template "${HOME_TEMPLATE}" "${ELEMENT_DIR}/home.html"
if [[ "${CLEANUP_HOME_TEMPLATE}" == "1" ]]; then
  rm -f "${HOME_TEMPLATE}"
fi

# --force-recreate: a plain `up -d` no-ops on a container that's already running with the same
# image/config hash even though config.json/welcome.html/home.html were just rewritten in place --
# a prior review caught the live container still serving a stale inode after a rename/rewrite.
# Force-recreating guarantees the container's bind mounts are re-resolved against the freshly
# rendered files every run, not just on first create.
log "  starting element (force-recreate so rendered config/welcome/home are always picked up)"
dc up -d --force-recreate --wait element

# ---------------------------------------------------------------------------
# Step 10: summary
# ---------------------------------------------------------------------------
log "Step 10/10: done"
echo
echo "================================================================"
echo " Rumi Messenger is up"
echo "================================================================"
echo " Element Web:   http://${BIND_ADDR}:${ELEMENT_PORT}"
echo " Synapse:       http://${BIND_ADDR}:${SYNAPSE_PORT}"
echo " TURN (calls):  ${TURN_HOST}:${TURN_PORT} (udp+tcp), relay ports ${TURN_MIN_PORT}-${TURN_MAX_PORT}"
echo "                plaintext only (no-tls; DTLS off by default) until issue #6; see docs/RUNBOOK.md"
echo " Server name:   ${SERVER_NAME}"
echo
echo " Admin account:   ${ADMIN_USER}"
if [[ -n "${GENERATED_ADMIN_PASSWORD}" ]]; then
  echo "   password (generated, shown once): ${GENERATED_ADMIN_PASSWORD}"
else
  echo "   password: unchanged (see deploy/.env)"
fi
echo " Bot account:     @rumi:${SERVER_NAME} (credentials in deploy/rumi-channel.env)"
echo "================================================================"
