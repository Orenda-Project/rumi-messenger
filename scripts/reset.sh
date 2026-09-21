#!/usr/bin/env bash
# Destroys the local Rumi Messenger stack: docker compose down -v + wipes synapse/data.
# Irreversible. Requires typing RESET to confirm.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
SYNAPSE_DATA_DIR="${DEPLOY_DIR}/synapse/data"

echo "This will permanently delete:"
echo "  - all docker compose volumes for this stack (Postgres data)"
echo "  - ${SYNAPSE_DATA_DIR} (homeserver config, signing key, media store)"
echo
read -r -p 'Type RESET to confirm: ' CONFIRM
if [[ "${CONFIRM}" != "RESET" ]]; then
  echo "Aborted (typed '${CONFIRM}', expected 'RESET')."
  exit 1
fi

cd "${DEPLOY_DIR}"
docker compose down -v

# synapse/data ends up owned by uid 991 inside the container -- remove it via a throwaway
# container instead of relying on host permissions.
if [[ -d "${SYNAPSE_DATA_DIR}" ]]; then
  docker run --rm -v "${SYNAPSE_DATA_DIR}:/target" alpine sh -c 'rm -rf /target/*'
  rm -rf "${SYNAPSE_DATA_DIR}"
fi

echo "Reset complete. Run scripts/setup.sh to rebuild from scratch."
