#!/usr/bin/env bash
# devices.sh list <user>            -- every device on an account, with display name and last seen
# devices.sh prune <user> [--yes]   -- remove devices with no display name that have never synced
#
# Why this exists: a device that never uploaded encryption keys (an API login, a half-finished
# sign-in) stays on the account forever. Once the owner verifies her identity, Element refuses to
# hand room keys to any device she has not signed, so every encrypted send from her new phone
# fails with a red mark and no explanation. Seen live on 23 Sep 2026, rumi-messenger#14.
# Uses only bash, curl and python3, like the other scripts here.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; DEPLOY="$HERE/../deploy"
# shellcheck disable=SC1091
source "$DEPLOY/.env"
HS="http://${BIND_ADDR:-127.0.0.1}:${SYNAPSE_PORT:-8008}"
cmd="${1:-}"; user="${2:-}"; [ -n "$cmd" ] && [ -n "$user" ] || { sed -n '2,3p' "$0"; exit 64; }
mxid="@${user#@}"; case "$mxid" in *:*) ;; *) mxid="$mxid:${SERVER_NAME}";; esac
enc="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$mxid")"
tok="$(curl -sS -X POST "$HS/_matrix/client/v3/login" -H 'Content-Type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${ADMIN_USER}\"},\"password\":\"${ADMIN_PASSWORD}\"}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')"
devices="$(curl -sS -H "Authorization: Bearer $tok" "$HS/_synapse/admin/v2/users/$enc/devices")"
case "$cmd" in
  list)
    python3 - "$devices" <<'PY'
import json,sys,datetime
d=json.loads(sys.argv[1]); print(f"{d['total']} device(s)")
for x in d["devices"]:
    seen=x.get("last_seen_ts"); seen=datetime.datetime.fromtimestamp(seen/1000).strftime("%Y-%m-%d %H:%M") if seen else "never"
    print(f"  {x['device_id']:<12} {(x.get('display_name') or '(no name)'):<34} last seen {seen}")
PY
    ;;
  prune)
    stale="$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(json.dumps([x["device_id"] for x in d["devices"] if not x.get("display_name") and not x.get("last_seen_ts")]))' "$devices")"
    n="$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$stale")"
    [ "$n" -gt 0 ] || { echo "nothing to prune: no unnamed, never-seen devices on $mxid"; exit 0; }
    echo "will remove $n unnamed, never-seen device(s) from $mxid: $stale"
    if [ "${3:-}" != "--yes" ]; then read -r -p "type PRUNE to confirm: " ok; [ "$ok" = "PRUNE" ] || { echo "aborted"; exit 1; }; fi
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
      "$HS/_synapse/admin/v2/users/$enc/delete_devices" -d "{\"devices\":$stale}")"
    [ "$code" = "200" ] && echo "removed. The owner's other devices can now encrypt to this account again." || { echo "delete_devices returned HTTP $code"; exit 1; }
    ;;
  *) sed -n '2,3p' "$0"; exit 64;;
esac
