#!/usr/bin/env bash
# railway-deploy.sh -- put Rumi Messenger on Railway (docs/RAILWAY.md). Idempotent: re-run it to
# redeploy after a `git pull`; it only creates what is missing.
#
#   railway login                      # once, in a browser
#   scripts/railway-deploy.sh          # creates/links project "rumi-messenger" and deploys
#   scripts/railway-bootstrap.sh       # then: admin + @rumi accounts, Rumi Announcements
#
# Optional env: RAILWAY_PROJECT (default rumi-messenger), RAILWAY_WORKSPACE (name or id; needed
# when your account has more than one), SERVICES="synapse element" to redeploy only some.
#
# What it makes: managed Postgres + five services built from deploy/railway/<service>/Dockerfile
# (build context = this repo; the same pinned images as deploy/docker-compose.yml), a Railway
# https domain per service, volumes for Synapse (/data) and ntfy (/var/lib/ntfy), and one TCP
# proxy for LiveKit's call media. Secrets are generated once into deploy/railway/.env.railway
# (chmod 600, gitignored) and set as Railway variables; nothing secret is committed or baked
# into an image. Needs: railway CLI (logged in), python3, openssl.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="${RUMI_ENV_FILE:-$ROOT/deploy/railway/.env.railway}"
PROJECT="${RAILWAY_PROJECT:-rumi-messenger}"
SERVICES="${SERVICES:-synapse element ntfy livekit lk-jwt}"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
cd "$ROOT"

railway whoami >/dev/null 2>&1 || { echo "not logged in: run 'railway login' first" >&2; exit 1; }

# 1. project (link if this repo is not linked yet; create only if the project does not exist)
if ! railway status >/dev/null 2>&1; then
  if railway list --json | python3 -c 'import json,sys; sys.exit(0 if any(p["name"]==sys.argv[1] for p in json.load(sys.stdin)) else 1)' "$PROJECT"; then
    log "linking existing project $PROJECT"
    railway link --project "$PROJECT" ${RAILWAY_WORKSPACE:+--workspace "$RAILWAY_WORKSPACE"} --environment production
  else
    log "creating project $PROJECT"
    railway init --name "$PROJECT" ${RAILWAY_WORKSPACE:+--workspace "$RAILWAY_WORKSPACE"}
  fi
fi

svc_json() { railway service list --json; }
has_service() { svc_json | python3 -c 'import json,sys; sys.exit(0 if any(s["name"]==sys.argv[1] for s in json.load(sys.stdin)) else 1)' "$1"; }

# 2. services + Postgres
has_service Postgres || { log "adding Postgres"; railway add --database postgres >/dev/null; }
for s in synapse element ntfy livekit lk-jwt; do
  has_service "$s" || { log "adding service $s"; railway add --service "$s" >/dev/null; }
done

# 3. one https domain per service, on the port its container listens on (= its PORT variable)
declare -A PORTS=([synapse]=8008 [element]=8080 [ntfy]=8080 [livekit]=7880 [lk-jwt]=8080)
domain_of() { railway domain list --service "$1" --json | python3 -c 'import json,sys; d=json.load(sys.stdin)["domains"]; print(d[0]["domain"] if d else "")'; }
for s in synapse element ntfy livekit lk-jwt; do
  [ -n "$(domain_of "$s")" ] || { log "generating domain for $s (port ${PORTS[$s]})"; railway domain --service "$s" --port "${PORTS[$s]}" >/dev/null; }
done

# 4. volumes (Railway: one per service). `volume add` acts on the LINKED service.
has_volume() { railway volume list --json | python3 -c 'import json,sys; sys.exit(0 if any(v.get("serviceName")==sys.argv[1] for v in json.load(sys.stdin)["volumes"]) else 1)' "$1"; }
for sv in synapse:/data ntfy:/var/lib/ntfy; do
  s="${sv%%:*}"; m="${sv#*:}"
  has_volume "$s" || { log "adding volume $m to $s"; railway service link "$s" >/dev/null; railway volume add -m "$m" >/dev/null; }
done

# 5. LiveKit media: Railway has no UDP, so ICE-TCP through the one TCP proxy a service may have.
if [ "$(railway tcp-proxy list --service livekit --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["proxies"]))')" = 0 ]; then
  log "creating TCP proxy for LiveKit media (application port 7881)"
  railway tcp-proxy create --port 7881 --service livekit >/dev/null
fi

# 6. secrets: generated ONCE, kept in the local file and in Railway variables only
umask 077; touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
getv() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
putv() { if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi; }
for k in REG_SHARED_SECRET ADMIN_PASSWORD RUMI_BOT_PASSWORD LIVEKIT_API_SECRET; do
  [ -n "$(getv "$k")" ] || putv "$k" "$(openssl rand -hex 24)"
done
[ -n "$(getv LIVEKIT_API_KEY)" ] || putv LIVEKIT_API_KEY "lkapi$(openssl rand -hex 8)"
[ -n "$(getv ADMIN_USER)" ] || putv ADMIN_USER admin
SYN="$(domain_of synapse)"
putv SERVER_NAME "$SYN"
putv SYNAPSE_URL "https://$SYN"
putv ELEMENT_URL "https://$(domain_of element)"
putv NTFY_BASE_URL "https://$(domain_of ntfy)"
putv COTURN off
log "settings in $ENV_FILE (chmod 600, gitignored): server https://$SYN"

# 7. variables (references ${{svc.VAR}} resolve inside Railway; single-quoted so bash leaves them)
setv() { local s="$1"; shift; railway variable set --service "$s" --skip-deploys "$@" >/dev/null; }
secret() { getv "$2" | railway variable set --service "$1" --skip-deploys "$2" --stdin >/dev/null; }
setv synapse RAILWAY_DOCKERFILE_PATH=deploy/railway/synapse/Dockerfile PORT=8008 \
  'DATABASE_URL=${{Postgres.DATABASE_URL}}' 'LIVEKIT_SERVICE_URL=https://${{lk-jwt.RAILWAY_PUBLIC_DOMAIN}}'
secret synapse REG_SHARED_SECRET
setv element RAILWAY_DOCKERFILE_PATH=deploy/railway/element/Dockerfile PORT=8080 'SERVER_NAME=${{synapse.RAILWAY_PUBLIC_DOMAIN}}'
setv ntfy RAILWAY_DOCKERFILE_PATH=deploy/railway/ntfy/Dockerfile PORT=8080
setv livekit RAILWAY_DOCKERFILE_PATH=deploy/railway/livekit/Dockerfile PORT=7880 'LK_JWT_URL=https://${{lk-jwt.RAILWAY_PUBLIC_DOMAIN}}'
secret livekit LIVEKIT_API_KEY; secret livekit LIVEKIT_API_SECRET
setv lk-jwt RAILWAY_DOCKERFILE_PATH=deploy/railway/lk-jwt/Dockerfile PORT=8080 \
  'LIVEKIT_URL=wss://${{livekit.RAILWAY_PUBLIC_DOMAIN}}' 'LIVEKIT_KEY=${{livekit.LIVEKIT_API_KEY}}' \
  'LIVEKIT_SECRET=${{livekit.LIVEKIT_API_SECRET}}' 'LIVEKIT_FULL_ACCESS_HOMESERVERS=${{synapse.RAILWAY_PUBLIC_DOMAIN}}'

# 8. build + deploy each service from this repo (gitignored files are never uploaded)
for s in $SERVICES; do
  log "deploying $s (railway up, build logs follow)"
  railway up --service "$s" --ci
done
log "deployed. Next: scripts/railway-bootstrap.sh, then RUMI_ENV_FILE=$ENV_FILE scripts/e2e.sh"
