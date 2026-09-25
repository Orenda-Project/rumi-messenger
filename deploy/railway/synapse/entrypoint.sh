#!/bin/bash
# Railway boot for Synapse. Volume at /data (homeserver.yaml, signing key, media), managed Postgres
# via DATABASE_URL. Idempotent: the patch runs every boot, generate only on the first.
set -euo pipefail
log() { echo "[rumi-entrypoint] $*"; }

: "${DATABASE_URL:?set DATABASE_URL=\${{Postgres.DATABASE_URL}} on this service}"
: "${REG_SHARED_SECRET:?set REG_SHARED_SECRET (a long random string) on this service}"
export SERVER_NAME="${SERVER_NAME:-${RAILWAY_PUBLIC_DOMAIN:-}}"
if [[ -z "${SERVER_NAME}" ]]; then
  log "ERROR: no SERVER_NAME and no Railway domain. Run: railway domain --service synapse --port 8008, then redeploy."
  exit 1
fi
export PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://${SERVER_NAME}}"
export REGISTRATION_MODE="${REGISTRATION_MODE:-token}"
export LISTEN_PORT="${PORT:-8008}"
export TURN_HOST="" TURN_PORT="" TURN_SHARED_SECRET="" LAN_IP=""    # no coturn on Railway (no UDP)
export LIVEKIT_SERVICE_URL="${LIVEKIT_SERVICE_URL:-}"
export CALLS="$([[ -n "${LIVEKIT_SERVICE_URL}" ]] && echo on || echo off)"
export SYNAPSE_DB_NAME="${SYNAPSE_DB_NAME:-synapse}"
export POSTGRES_PASSWORD=""   # unused when DATABASE_URL is set; the patch reads it only on compose

mkdir -p /data
if [[ ! -f /data/homeserver.yaml ]]; then
  log "first boot: generating homeserver.yaml + signing key for server_name=${SERVER_NAME}"
  SYNAPSE_SERVER_NAME="${SERVER_NAME}" SYNAPSE_REPORT_STATS=no /start.py generate
fi

# server_name is baked into every user id and the signing key. A different Railway/custom domain
# later is a DIFFERENT server; refuse to boot rather than silently corrupt identities.
CURRENT="$(python3 -c 'import yaml;print(yaml.safe_load(open("/data/homeserver.yaml"))["server_name"])')"
if [[ "${CURRENT}" != "${SERVER_NAME}" ]]; then
  log "ERROR: /data/homeserver.yaml was generated for server_name=${CURRENT}, but this boot says ${SERVER_NAME}."
  log "       Set SERVER_NAME=${CURRENT} on this service (keep the old identity), or wipe the volume AND the database for a new server."
  exit 1
fi

# Synapse refuses a database whose collation is not C (the Railway Postgres default is not), so
# create one C-collated database next to Railway's default "railway" one. Idempotent.
python3 - <<'PYEOF'
import os, psycopg2
from psycopg2 import sql
name = os.environ["SYNAPSE_DB_NAME"]
conn = psycopg2.connect(os.environ["DATABASE_URL"])
conn.autocommit = True
cur = conn.cursor()
cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (name,))
if cur.fetchone():
    print(f"[rumi-entrypoint] database {name} exists")
else:
    cur.execute(sql.SQL("CREATE DATABASE {} ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0").format(sql.Identifier(name)))
    print(f"[rumi-entrypoint] created C-collated database {name}")
PYEOF

python3 /rumi/patch_homeserver.py
chmod 600 /data/homeserver.yaml "/data/${SERVER_NAME}.signing.key"
# Railway volumes mount root-owned; Synapse runs as 991 (start.py drops to it with gosu).
find /data ! -user 991 -exec chown 991:991 {} +
log "starting Synapse: server_name=${SERVER_NAME} public_baseurl=${PUBLIC_BASE_URL} port=${LISTEN_PORT} calls=${CALLS}"
exec /start.py
