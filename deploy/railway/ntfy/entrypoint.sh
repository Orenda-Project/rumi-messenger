#!/bin/sh
# Settings mirror deploy/docker-compose.yml's ntfy service (see its comments for the why).
# base-url MUST be this service's own public https URL: ntfy's Matrix gateway rejects a pushkey
# that does not start with it, and the phone's ntfy app must use exactly this address.
set -eu
export NTFY_BASE_URL="${NTFY_BASE_URL:-https://${RAILWAY_PUBLIC_DOMAIN:?no Railway domain yet: railway domain --service ntfy --port 8080}}"
export NTFY_LISTEN_HTTP=":${PORT:-80}"
export NTFY_CACHE_FILE=/var/lib/ntfy/cache.db NTFY_AUTH_FILE=/var/lib/ntfy/auth.db
export NTFY_AUTH_DEFAULT_ACCESS=deny-all NTFY_AUTH_ACCESS='*:up*:read-write'
export NTFY_VISITOR_SUBSCRIBER_RATE_LIMITING=true NTFY_BEHIND_PROXY=true
mkdir -p /var/lib/ntfy
echo "rumi: ntfy base-url ${NTFY_BASE_URL}, listening ${NTFY_LISTEN_HTTP}"
exec ntfy serve
