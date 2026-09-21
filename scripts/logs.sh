#!/usr/bin/env bash
# Tail logs for the Rumi Messenger stack. `docker logs` IS the log (JSON lines for synapse).
#
# Usage:
#   scripts/logs.sh              # tail all services
#   scripts/logs.sh -s synapse   # tail just one service (synapse|postgres|element|caddy)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"

SERVICE=""
while getopts "s:" opt; do
  case "${opt}" in
    s) SERVICE="${OPTARG}" ;;
    *) echo "Usage: $0 [-s service]" >&2; exit 1 ;;
  esac
done

cd "${DEPLOY_DIR}"
if [[ -n "${SERVICE}" ]]; then
  docker compose logs -f --tail=200 "${SERVICE}"
else
  docker compose logs -f --tail=200
fi
