#!/usr/bin/env bash
# Rumi Messenger -- wires this stack's @rumi bot credentials into a rumi-platform checkout's
# .env, so `rumi start` there picks up the Matrix channel. Idempotent: safe to re-run any time
# (backs up the target .env before touching it, every time).
#
# Usage:
#   scripts/connect-rumi.sh <path-to-rumi-platform-checkout>
#
# Requires: bash, and that scripts/setup.sh has already run in THIS repo (so
# deploy/rumi-channel.env exists).
set -euo pipefail

usage() {
  echo "Usage: $0 <path-to-rumi-platform-checkout>" >&2
  echo "  Writes MATRIX_HOMESERVER_URL, MATRIX_ACCESS_TOKEN, MATRIX_USER_ID from" >&2
  echo "  deploy/rumi-channel.env into <path>/.env (created from .env.template if missing)." >&2
}

if [[ $# -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
# RUMI_CHANNEL_ENV=deploy/railway/rumi-channel.env connects a Railway deployment (docs/RAILWAY.md).
CHANNEL_ENV_FILE="${RUMI_CHANNEL_ENV:-${REPO_ROOT}/deploy/rumi-channel.env}"

TARGET_DIR_INPUT="$1"
if [[ ! -d "${TARGET_DIR_INPUT}" ]]; then
  echo "ERROR: '${TARGET_DIR_INPUT}' is not a directory." >&2
  exit 1
fi
TARGET_DIR="$(cd -- "${TARGET_DIR_INPUT}" >/dev/null 2>&1 && pwd)"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

# ---------------------------------------------------------------------------
# 1. Validate this looks like a real rumi-platform checkout
# ---------------------------------------------------------------------------
if [[ ! -f "${TARGET_DIR}/bot/whatsapp-bot.js" ]]; then
  echo "ERROR: '${TARGET_DIR}/bot/whatsapp-bot.js' not found -- '${TARGET_DIR}' does not look like a rumi-platform checkout." >&2
  exit 1
fi
if [[ ! -f "${TARGET_DIR}/.env.template" ]]; then
  echo "ERROR: '${TARGET_DIR}/.env.template' not found -- '${TARGET_DIR}' does not look like a rumi-platform checkout." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Read deploy/rumi-channel.env from THIS repo
# ---------------------------------------------------------------------------
if [[ ! -f "${CHANNEL_ENV_FILE}" ]]; then
  echo "ERROR: ${CHANNEL_ENV_FILE} not found -- run scripts/setup.sh in this repo first." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "${CHANNEL_ENV_FILE}"
set +a

if [[ -z "${MATRIX_HOMESERVER_URL:-}" || -z "${MATRIX_ACCESS_TOKEN:-}" || -z "${MATRIX_USER_ID:-}" ]]; then
  echo "ERROR: ${CHANNEL_ENV_FILE} is missing one of MATRIX_HOMESERVER_URL/MATRIX_ACCESS_TOKEN/MATRIX_USER_ID." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Ensure target .env exists (create from .env.template if missing), back it up
# ---------------------------------------------------------------------------
TARGET_ENV="${TARGET_DIR}/.env"
CREATED_ENV=0
if [[ ! -f "${TARGET_ENV}" ]]; then
  cp "${TARGET_DIR}/.env.template" "${TARGET_ENV}"
  CREATED_ENV=1
  log "created ${TARGET_ENV} from .env.template"
else
  BACKUP_FILE="${TARGET_ENV}.bak.$(date +%s)"
  cp "${TARGET_ENV}" "${BACKUP_FILE}"
  log "backed up existing .env -> $(basename "${BACKUP_FILE}")"
fi

# ---------------------------------------------------------------------------
# 4. Write/update MATRIX_HOMESERVER_URL, MATRIX_ACCESS_TOKEN, MATRIX_USER_ID
# ---------------------------------------------------------------------------
set_env_var() {
  local file="$1" key="$2" value="$3"
  # Escape sed special characters in the replacement value.
  local escaped
  escaped="$(printf '%s' "${value}" | sed -e 's/[&/\]/\\&/g')"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "${file}"
    echo "updated"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    echo "added"
  fi
}

CHANGES=()
for VAR in MATRIX_HOMESERVER_URL MATRIX_ACCESS_TOKEN MATRIX_USER_ID; do
  eval "VALUE=\"\${${VAR}}\""
  ACTION="$(set_env_var "${TARGET_ENV}" "${VAR}" "${VALUE}")"
  CHANGES+=("${VAR}: ${ACTION}")
done

# ---------------------------------------------------------------------------
# 5. chmod 600, print a summary WITHOUT the token value
# ---------------------------------------------------------------------------
chmod 600 "${TARGET_ENV}"

echo
echo "================================================================"
echo " Connected: ${TARGET_DIR}"
echo "================================================================"
if [[ "${CREATED_ENV}" -eq 1 ]]; then
  echo " .env: created from .env.template"
else
  echo " .env: existing file backed up before edit"
fi
for change in "${CHANGES[@]}"; do
  echo " ${change}"
done
echo " .env permissions: 600"
echo
echo " Next: cd '${TARGET_DIR}' && node -v (want >=24 for E2EE) && rumi start"
echo " Then verify with: node bot/scripts/matrix-smoke.js (see docs/RUMI-INTEGRATION.md)"
echo "================================================================"
