#!/usr/bin/env bash
# Backs up Postgres (pg_dump) + the Synapse media store into backups/<timestamp>/.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found -- run scripts/setup.sh first" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
OUT_DIR="${REPO_ROOT}/backups/${TS}"
mkdir -p "${OUT_DIR}"

echo "[backup] dumping postgres -> ${OUT_DIR}/postgres.sql"
(cd "${DEPLOY_DIR}" && docker compose exec -T postgres pg_dump -U synapse synapse) > "${OUT_DIR}/postgres.sql"

MEDIA_DIR="${DEPLOY_DIR}/synapse/data/media_store"
if [[ -d "${MEDIA_DIR}" ]]; then
  echo "[backup] archiving media_store -> ${OUT_DIR}/media_store.tar.gz"
  # media_store is owned by uid 991 inside the container; tar it via a throwaway container
  # so this doesn't depend on host read permissions.
  docker run --rm \
    -v "${MEDIA_DIR}:/media_store:ro" \
    -v "${OUT_DIR}:/out" \
    alpine tar -czf /out/media_store.tar.gz -C / media_store
else
  echo "[backup] no media_store found, skipping"
fi

echo "[backup] done: ${OUT_DIR}"
du -sh "${OUT_DIR}"/* 2>/dev/null || true
