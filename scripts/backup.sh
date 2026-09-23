#!/usr/bin/env bash
# Backs up Postgres (pg_dump) + the Synapse media store + signing key into backups/<timestamp>/,
# restore-verifies the Postgres dump against a throwaway scratch container, then prunes old
# backups down to BACKUP_KEEP_N (deploy/.env, default 14). Issue #6 (production hardening) --
# see docs/RUNBOOK.md's "Backups and restore" section for the scheduling line and manual
# media/signing-key restore steps this script does not perform for you (a real restore should be
# deliberate, not a script silently overwriting live data -- see that section for why).
#
# Pass --skip-verify to skip the restore-verification step (e.g. for a very large media store
# where the goal is just "did the backup files get written", not the full proof).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
ENV_FILE="${DEPLOY_DIR}/.env"
BACKUPS_DIR="${REPO_ROOT}/backups"

SKIP_VERIFY=0
if [[ "${1:-}" == "--skip-verify" ]]; then
  SKIP_VERIFY=1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found -- run scripts/setup.sh first" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
BACKUP_KEEP_N="${BACKUP_KEEP_N:-14}"

TS="$(date -u +'%Y%m%dT%H%M%SZ')"
OUT_DIR="${BACKUPS_DIR}/${TS}"
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

# The homeserver signing key proves this server's identity to clients/federation and to itself
# (device/cross-signing trust chains) -- losing it without a backup means every device has to
# re-verify from scratch, same blast radius as losing the Postgres data. Named
# "<SERVER_NAME>.signing.key" (scripts/setup.sh Step 2/3); glob it rather than hardcoding the
# name so a SERVER_NAME change is still picked up.
SIGNING_KEYS=("${DEPLOY_DIR}"/synapse/data/*.signing.key)
if [[ -e "${SIGNING_KEYS[0]}" ]]; then
  echo "[backup] copying signing key(s) -> ${OUT_DIR}/"
  # Owned by uid 991 inside the container (chmod 600 by setup.sh); cp via a throwaway container
  # for the same reason media_store is tarred that way above, rather than assuming host read
  # permission on a 600 file owned by a container-only uid.
  docker run --rm \
    -v "${DEPLOY_DIR}/synapse/data:/data:ro" \
    -v "${OUT_DIR}:/out" \
    alpine sh -c 'cp /data/*.signing.key /out/ 2>/dev/null || true'
else
  echo "[backup] WARNING: no *.signing.key found under deploy/synapse/data -- skipping (has setup.sh run?)"
fi

echo "[backup] done: ${OUT_DIR}"
du -sh "${OUT_DIR}"/* 2>/dev/null || true

# ---------------------------------------------------------------------------
# Restore verification -- the half of a backup that's never tested until the day it matters.
# Spins a throwaway, fully isolated scratch Postgres (its own container, no shared volume/network
# with the real stack), restores THIS backup's postgres.sql into it, and counts rows in the
# `users` table as proof the dump is a real, loadable Synapse database, not just non-empty bytes.
# Torn down unconditionally (trap) whether the restore succeeds or fails.
# ---------------------------------------------------------------------------
if [[ "${SKIP_VERIFY}" == "1" ]]; then
  echo "[backup] --skip-verify given, not restore-testing"
else
  VERIFY_CONTAINER="rumi-backup-verify-${TS}"
  VERIFY_PASSWORD="verify-only-$(openssl rand -hex 8)"

  cleanup_verify() {
    docker rm -f "${VERIFY_CONTAINER}" >/dev/null 2>&1 || true
  }
  trap cleanup_verify EXIT

  echo "[backup] restore-verify: starting scratch postgres (${VERIFY_CONTAINER})"
  docker run -d --name "${VERIFY_CONTAINER}" \
    -e POSTGRES_USER=synapse -e POSTGRES_PASSWORD="${VERIFY_PASSWORD}" -e POSTGRES_DB=synapse \
    -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C" -e LC_ALL=C -e LANG=C \
    postgres:16.15-alpine >/dev/null

  echo "[backup] restore-verify: waiting for scratch postgres to accept connections"
  # pg_isready alone is not enough here: postgres's own initdb-on-first-start does a full
  # restart partway through bootstrapping (documented Postgres Docker image behavior), during
  # which pg_isready can report ready right before the "shutting down for restart" window --
  # discovered live, the first version of this script raced exactly that window. Requiring an
  # actual successful query is what proves it's really up, not just answering the readiness ping.
  READY=0
  for i in $(seq 1 60); do
    if docker exec "${VERIFY_CONTAINER}" psql -U synapse -d synapse -tAc "SELECT 1;" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 1
  done
  if [[ "${READY}" != "1" ]]; then
    echo "[backup] ERROR: scratch postgres never became ready" >&2
    exit 1
  fi

  echo "[backup] restore-verify: loading ${OUT_DIR}/postgres.sql into scratch postgres"
  docker exec -i "${VERIFY_CONTAINER}" psql -U synapse -d synapse -v ON_ERROR_STOP=1 \
    < "${OUT_DIR}/postgres.sql" >/dev/null

  USER_COUNT="$(docker exec "${VERIFY_CONTAINER}" psql -U synapse -d synapse -tA \
    -c "SELECT count(*) FROM users;")"
  USER_COUNT="$(echo "${USER_COUNT}" | tr -d '[:space:]')"

  if [[ -z "${USER_COUNT}" ]]; then
    echo "[backup] RESTORE VERIFICATION FAILED: could not read users table row count" >&2
    exit 1
  fi

  echo "[backup] RESTORE VERIFIED: users table has ${USER_COUNT} row(s) after restoring this backup into a scratch database"
fi

# ---------------------------------------------------------------------------
# Rotation -- keep the newest BACKUP_KEEP_N timestamped folders, delete the rest.
# ---------------------------------------------------------------------------
if [[ -d "${BACKUPS_DIR}" ]]; then
  mapfile -t ALL_BACKUPS < <(find "${BACKUPS_DIR}" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort)
  TOTAL="${#ALL_BACKUPS[@]}"
  if (( TOTAL > BACKUP_KEEP_N )); then
    TO_DELETE=$(( TOTAL - BACKUP_KEEP_N ))
    echo "[backup] rotation: ${TOTAL} backups on disk, keeping newest ${BACKUP_KEEP_N}, removing ${TO_DELETE} oldest"
    for ((i = 0; i < TO_DELETE; i++)); do
      echo "[backup]   removing ${ALL_BACKUPS[$i]}"
      rm -rf "${ALL_BACKUPS[$i]}"
    done
  else
    echo "[backup] rotation: ${TOTAL} backups on disk, under BACKUP_KEEP_N=${BACKUP_KEEP_N}, nothing to remove"
  fi
fi
