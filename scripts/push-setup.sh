#!/usr/bin/env bash
# Rumi Messenger -- phone push setup (issue #3). Idempotent: safe to re-run any time.
#   1. Starts self-hosted ntfy (compose profile "push"): the UnifiedPush server + Matrix push
#      gateway for the no-Google path. Needs no keys, always started.
#   2. Renders deploy/sygnal/sygnal.yaml and starts Sygnal (the FCM/Google path) ONLY if a real
#      FCM service account file is present.
# See docs/PUSH.md.
#
# Requires only: docker (with the compose plugin), python3. Run scripts/setup.sh first (this
# script reads deploy/.env, which setup.sh creates).
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (works from any cwd)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"
SYGNAL_DIR="${DEPLOY_DIR}/sygnal"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

dc() {
  (cd "${DEPLOY_DIR}" && docker compose "$@")
}

if [[ ! -f "${ENV_FILE}" ]]; then
  log "ERROR: ${ENV_FILE} not found -- run scripts/setup.sh first"
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "${ENV_FILE}"
set +a

PUSH_APP_ID="${PUSH_APP_ID:-ai.hellorumi.messenger}"
FCM_SERVICE_ACCOUNT_JSON="${FCM_SERVICE_ACCOUNT_JSON:-${SYGNAL_DIR}/fcm-service-account.json}"
SYGNAL_PORT="${SYGNAL_PORT:-5000}"
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"

# FCM_SERVICE_ACCOUNT_JSON in deploy/.env can be relative (to deploy/) or absolute -- resolve it
# the same way the rest of this script's paths are resolved, so a relative value in .env behaves
# the same regardless of the caller's cwd.
if [[ "${FCM_SERVICE_ACCOUNT_JSON}" != /* ]]; then
  FCM_SERVICE_ACCOUNT_JSON="${DEPLOY_DIR}/${FCM_SERVICE_ACCOUNT_JSON#./}"
fi

mkdir -p "${SYGNAL_DIR}"

# ---------------------------------------------------------------------------
# Step 1: check for a REAL FCM service account file. Never fabricate one.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Step 0: self-hosted ntfy (UnifiedPush, no Google). No credentials involved.
# ---------------------------------------------------------------------------
NTFY_BASE_URL="${NTFY_BASE_URL:-https://ntfy.${PUBLIC_DOMAIN:-localhost}}"
log "Step 0/3: starting ntfy (UnifiedPush server + Matrix gateway) at ${NTFY_BASE_URL}"
dc --profile push up -d --wait ntfy
log "  ntfy up: phones point the ntfy app at ${NTFY_BASE_URL} (docs/PUSH.md); verify with scripts/push-check.sh"

log "Step 1/3: checking for a real FCM service account file"
HAVE_FCM_KEY=0
FCM_PROJECT_ID=""
if [[ -f "${FCM_SERVICE_ACCOUNT_JSON}" ]]; then
  # Sanity-check the shape (type == "service_account", has project_id) rather than trusting any
  # file that happens to exist at the path -- a placeholder/empty file left by mistake must not
  # be treated as real credentials.
  FCM_PROJECT_ID="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if d.get('type') != 'service_account' or not d.get('project_id'):
    sys.exit(1)
print(d['project_id'])
" "${FCM_SERVICE_ACCOUNT_JSON}" 2>/dev/null || true)"
  if [[ -n "${FCM_PROJECT_ID}" ]]; then
    HAVE_FCM_KEY=1
    log "  found a real service account file for Firebase project '${FCM_PROJECT_ID}'"
  else
    log "  WARNING: ${FCM_SERVICE_ACCOUNT_JSON} exists but is not a valid Firebase service"
    log "  account JSON (needs \"type\": \"service_account\" and a \"project_id\") -- treating as missing"
  fi
else
  log "  no file at ${FCM_SERVICE_ACCOUNT_JSON} -- see docs/PUSH.md for how to get one"
fi

# ---------------------------------------------------------------------------
# Step 2: render deploy/sygnal/sygnal.yaml
# ---------------------------------------------------------------------------
log "Step 2/3: rendering deploy/sygnal/sygnal.yaml"
python3 - "${SYGNAL_DIR}/sygnal.yaml" "${SYGNAL_PORT}" "${PUSH_APP_ID}" "${HAVE_FCM_KEY}" "${FCM_SERVICE_ACCOUNT_JSON}" "${FCM_PROJECT_ID}" <<'PYEOF'
import sys

out_path, port, app_id, have_key, key_path, project_id = sys.argv[1:7]
have_key = have_key == "1"

# The service account file is mounted into the container at the same path it renders here
# (deploy/sygnal/*, mounted at /data in docker-compose.yml), so the in-container path is
# /data/<basename>.
key_basename = key_path.rsplit("/", 1)[-1]
in_container_key_path = f"/data/{key_basename}"

if have_key:
    apps_block_lines = []
    # Register both the release app id and its debug variant (element-x-android's debug build
    # type suffixes the applicationId with ".debug") against the SAME Firebase project/service
    # account -- Firebase does not require a separate project per build variant, just a
    # consistent google-services.json in the Android checkout matching this project id.
    for suffix in ("", ".debug"):
        apps_block_lines.append(f"""  {app_id}{suffix}:
    type: gcm
    api_version: v1
    project_id: {project_id}
    service_account_file: {in_container_key_path}
""")
    apps_block = "\n".join(apps_block_lines)
else:
    apps_block = f"""  # {app_id} (and {app_id}.debug) are NOT configured -- no real FCM service
  # account JSON was found at setup time (FCM_SERVICE_ACCOUNT_JSON in deploy/.env). See
  # docs/PUSH.md for how to get one from the Firebase console; re-run scripts/push-setup.sh
  # once you have it and this section fills in automatically, no manual edit needed.
  #
  # DISCOVERED LIVE, 2026-09-23: Sygnal does NOT start with zero apps configured -- it exits
  # immediately with "RuntimeError: No app IDs are configured. Edit sygnal.yaml to define some."
  # (sygnal/sygnal.py, make_pushkins_then_start). That's why this script refuses to bring the
  # container up at all in this state (see the caller below) rather than starting a gateway that
  # would just crash-loop -- scripts/push-check.sh's GET /health check then correctly reports
  # "unreachable" instead of hanging or printing a raw traceback, which is the honest signal
  # here: there is nothing running to be reachable until a real service account file exists.
"""

content = f"""# Rendered by scripts/push-setup.sh -- edit deploy/.env (PUSH_APP_ID,
# FCM_SERVICE_ACCOUNT_JSON, SYGNAL_PORT), not this file, then re-run scripts/push-setup.sh.
# See docs/PUSH.md.
log:
  setup:
    version: 1
    formatters:
      normal:
        format: "%(asctime)s [%(process)d] %(levelname)-5s %(name)s %(message)s"
    handlers:
      stdout:
        class: "logging.StreamHandler"
        formatter: "normal"
        stream: "ext://sys.stdout"
    loggers:
      sygnal.access:
        propagate: false
        handlers: ["stdout"]
        level: "INFO"
    root:
      handlers: ["stdout"]
      level: "INFO"
    disable_existing_loggers: false

http:
  bind_addresses: ['0.0.0.0']
  port: {port}

apps:
{apps_block}
  # --- APNs (iOS) -- commented out until issue #13 (needs a Mac + iPhone this environment
  # doesn't have, to fork element-x-ios and build/test against it). When that lands, an entry
  # here looks like:
  # {app_id}.ios:
  #   type: apns
  #   keyfile: /data/apns-auth-key.p8
  #   key_id: REPLACE_WITH_REAL_APNS_KEY_ID
  #   team_id: REPLACE_WITH_REAL_APPLE_TEAM_ID
  #   topic: {app_id}
"""
with open(out_path, "w") as f:
    f.write(content)
print(f"wrote {out_path}")
PYEOF
chmod 600 "${SYGNAL_DIR}/sygnal.yaml"
log "  wrote deploy/sygnal/sygnal.yaml (chmod 600)"

# ---------------------------------------------------------------------------
# Step 3: start (or refuse to start) sygnal
# ---------------------------------------------------------------------------
log "Step 3/3: starting sygnal (push profile)"
if [[ "${HAVE_FCM_KEY}" == "1" ]]; then
  dc --profile push up -d --force-recreate --wait sygnal
  echo
  echo "================================================================"
  echo " Sygnal is up: http://${BIND_ADDR}:${SYGNAL_PORT}"
  echo " Real FCM credentials found for project '${FCM_PROJECT_ID}' -- Android push should work"
  echo " once google-services.json in the app fork matches this project."
  echo " Verify with: scripts/push-check.sh"
  echo "================================================================"
else
  log "  REFUSING to start sygnal: no real FCM_SERVICE_ACCOUNT_JSON found"
  log "  (sygnal.yaml was rendered with zero apps configured, see above -- that's the honest"
  log "  state: a gateway with nothing to deliver through is not a working push gateway)"
  log "  see docs/PUSH.md for the exact steps to get a real key, then re-run this script"
  echo
  echo "================================================================"
  echo " Sygnal NOT started -- no real FCM credentials at ${FCM_SERVICE_ACCOUNT_JSON}"
  echo " Sygnal itself refuses to run with zero apps configured (exits immediately, see above),"
  echo " so there is nothing useful to start without a real credential file -- get one, set"
  echo " FCM_SERVICE_ACCOUNT_JSON in deploy/.env, then re-run this script. See docs/PUSH.md."
  echo "================================================================"
fi
