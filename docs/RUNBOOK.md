# Runbook -- Day-2 Operations

Everything here was run against the live stack on this repo (`deploy/.env`: `SERVER_NAME=localhost`,
Synapse on `127.0.0.1:8108`, Element on `127.0.0.1:8182`). Substitute your own `SERVER_NAME`,
ports, and admin credentials.

## Start / stop

```bash
cd deploy
docker compose up -d              # start (or restart) everything
docker compose stop               # stop, keep volumes
docker compose up -d              # start again -- picks up where it left off
```

`scripts/setup.sh` is safe to re-run any time -- it skips every step that's already done
(existing `.env`, existing `homeserver.yaml`, existing users) and only re-renders
`config.json`/`welcome.html`/`home.html` and force-recreates `element` so the freshly rendered
files are always picked up.

To stop everything and delete all data, use `scripts/reset.sh` -- it asks you to type `RESET`
first. There is no undo; take a backup first (below) if you might want the data back.

## Logs

```bash
scripts/logs.sh              # tail all services
scripts/logs.sh -s synapse   # tail just one (synapse | postgres | element | caddy)
```

`docker logs` **is** the log -- there's no separate log file to find. Synapse's lines are JSON;
see [LOGGING.md](LOGGING.md) for the field reference and what a healthy line looks like.

## Backups and restore

```bash
scripts/backup.sh
```

Writes `backups/<UTC timestamp>/postgres.sql` (a `pg_dump` of the `synapse` database) and
`backups/<UTC timestamp>/media_store.tar.gz` (everything under
`deploy/synapse/data/media_store`). Verified on this stack:

```
[backup] dumping postgres -> backups/20260921T095241Z/postgres.sql
[backup] archiving media_store -> backups/20260921T095241Z/media_store.tar.gz
[backup] done: backups/20260921T095241Z
```

**Restore** (not scripted -- do this deliberately, and stop Synapse first):

```bash
cd deploy
docker compose stop synapse

# Postgres
cat ../backups/<timestamp>/postgres.sql | docker compose exec -T postgres psql -U synapse -d synapse

# Media store (as root inside a throwaway container, same reasoning backup.sh uses --
# media_store is owned by uid 991 inside the synapse container)
docker run --rm -v "$(pwd)/synapse/data:/data" -v "$(pwd)/../backups/<timestamp>:/backup:ro" \
  alpine sh -c 'rm -rf /data/media_store && tar -xzf /backup/media_store.tar.gz -C /data'

docker compose start synapse
```

A restore replaces live data with the backup's -- anything sent between the backup and the
restore is gone. There's no partial/incremental restore here; back up on a schedule (cron +
`scripts/backup.sh`) if you need finer recovery points, and prune `backups/` yourself -- nothing
does it for you.

## Upgrading pinned images

Every image in `deploy/docker-compose.yml` is pinned to an exact tag with a comment describing
how to move it forward. As of this write-up:

| Service | Pinned tag | To upgrade |
|---|---|---|
| `postgres` | `postgres:16.15-alpine` | Bump to a newer `16.x-alpine` freely. A `17.x` major bump needs a `pg_upgrade` migration Synapse does not run for you -- don't jump majors casually. |
| `synapse` | `matrixdotorg/synapse:v1.161.0` | Check [element-hq/synapse releases](https://github.com/element-hq/synapse/releases) for the new version's upgrade notes (schema migrations occasionally require a specific version path -- don't skip multiple majors in one jump), bump the tag, `docker compose pull && docker compose up -d synapse`. |
| `element` | `vectorim/element-web:v1.12.28` | Check [element-hq/element-web releases](https://github.com/element-hq/element-web/releases), bump the tag, `docker compose pull && docker compose up -d element`. |

General sequence:

```bash
cd deploy
# edit docker-compose.yml: bump the tag(s)
docker compose pull
docker compose up -d
scripts/../scripts/e2e.sh   # from repo root: scripts/e2e.sh -- confirm nothing broke
```

Never move a tag back to `:latest` -- it defeats the whole point of pinning (see
`docs/DECISIONS.tsv`, 2026-09-21).

## Moving to a real domain (TLS)

By default Synapse and Element bind to `127.0.0.1` only -- nothing is reachable off the host. To
serve a real domain with TLS, use the `tls` Compose profile, which brings up Caddy
(`deploy/Caddyfile`) as the front door:

```bash
# in deploy/.env:
SERVER_NAME=chat.yourschool.org
PUBLIC_BASE_URL=https://chat.yourschool.org
BIND_ADDR=0.0.0.0        # so Caddy (and only Caddy) is reachable from outside

cd deploy
docker compose --profile tls up -d
```

`SERVER_NAME` is baked into every Matrix user id and room alias **at homeserver-generation
time** -- if you already ran `setup.sh` with `SERVER_NAME=localhost`, changing it later means
regenerating the homeserver (`scripts/reset.sh`, then `setup.sh` again with the real domain) --
existing accounts on `localhost` don't carry over. Decide your real domain before you invite real
teachers.

Caddy handles `/.well-known/matrix/server` and `/.well-known/matrix/client` for you (see
`deploy/Caddyfile`), so clients can discover your homeserver from just the domain, and gets you
automatic TLS via Let's Encrypt as long as ports 80/443 are reachable from the internet for the
ACME challenge.

## Registration modes

Set in `deploy/.env` (`REGISTRATION_MODE`), applied by `scripts/setup.sh` step 3:

- **`open`** (default) -- anyone who can reach Synapse can register. Fine for a closed network or
  a demo; not what you want once the URL is public.
- **`token`** -- registration requires a one-time token. Switch to this before exposing a
  deployment publicly:

  ```bash
  # deploy/.env: REGISTRATION_MODE=token
  scripts/setup.sh   # re-patches homeserver.yaml, restarts synapse
  ```

Minting a registration token (verified against the live stack -- the admin token comes from
logging in as `ADMIN_USER`/`ADMIN_PASSWORD` from `deploy/.env`):

```bash
ADMIN_TOKEN=$(curl -s -X POST http://127.0.0.1:8108/_matrix/client/v3/login \
  -H "Content-Type: application/json" \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"admin"},"password":"<ADMIN_PASSWORD from deploy/.env>"}' \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

curl -s -X POST http://127.0.0.1:8108/_synapse/admin/v1/registration_tokens/new \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"uses_allowed": 5}'
# -> {"token":"<token>","uses_allowed":5,"pending":0,"completed":0,"expiry_time":null}
```

Give that `token` value to whoever you want to invite; they enter it during registration
(Element's sign-up flow asks for it automatically when the server requires one).

## Creating and deactivating users

**Create/set a user directly** (admin API, no interactive prompt -- this is what to use for
scripting; `register_new_matrix_user` inside the container works too but needs `--no-admin` or
`-a`, or it hangs on an interactive prompt):

```bash
curl -s -X PUT "http://127.0.0.1:8108/_synapse/admin/v2/users/@newteacher:localhost" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"password":"a-real-password","admin":false}'
```

**Deactivate a user** (also erases their profile data if `erase: true`):

```bash
curl -s -X POST "http://127.0.0.1:8108/_synapse/admin/v1/deactivate/@newteacher:localhost" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"erase": true}'
# -> {"id_server_unbind_result":"success"}
```

Both verified live above against a throwaway `@runbooktest:localhost` account.

## Rate limits

Synapse's rate limits live in `homeserver.yaml` under the `rc_*` keys (`rc_message`,
`rc_registration`, `rc_login`, `rc_joins`, etc.) -- this stack ships Synapse's own defaults
(`scripts/setup.sh` doesn't touch them). They exist to stop a single client from hammering the
server, not to throttle normal classroom traffic; you're unlikely to need to change them for a
school-sized deployment. If you do (e.g. a bulk-import script tripping `rc_registration` while
creating many accounts at once), edit `deploy/synapse/data/homeserver.yaml` directly and restart:

```bash
cd deploy && docker compose restart synapse
```

Full key reference: [Synapse's rate-limiting
docs](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#ratelimiting).

## Media retention

`max_upload_size: 50M` is set by `scripts/setup.sh`. Synapse keeps uploaded media indefinitely by
default -- nothing in this stack prunes it automatically. To reclaim space from media nobody has
requested in a while, use the admin purge endpoint:

```bash
# deletes remote (federated) media not accessed since the given timestamp -- safe on a
# single-homeserver deployment with no federation, where this simply does nothing
curl -s -X POST "http://127.0.0.1:8108/_synapse/admin/v1/purge_media_cache?before_ts=$(($(date +%s%N)/1000000 - 30*24*60*60*1000))" \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

For **locally-uploaded** media (the kind this stack actually accumulates -- avatars, images,
documents teachers send), Synapse's admin API can purge unreferenced media per room via `POST
/_synapse/admin/v1/rooms/<room_id>/media/quarantine` and delete-by-room via `DELETE
/_synapse/admin/v1/rooms/<room_id>/media`. Deleting media is irreversible -- back up
`media_store` (`scripts/backup.sh`) before running either against a real deployment. Full
reference: [Synapse's media admin
API](https://element-hq.github.io/synapse/latest/admin_api/media_admin_api.html).

## Common failures

| Symptom | Exact error text | Fix |
|---|---|---|
| `setup.sh` hangs, then fails creating the `rumi` user | `ERROR creating user 'rumi': ... EOFError when reading a line` | Already fixed in this repo's `setup.sh` (`--no-admin`, not a blank flag, plus `--exists-ok`) -- if you see this on a modified copy, check you didn't drop those flags from the `register_new_matrix_user` call. |
| A second `setup.sh` run rebinds the wrong port | You exported `SYNAPSE_PORT=8208` but the stack still comes up on 8008 | Fixed in this repo -- `setup.sh` now captures pre-exported overrides before sourcing `.env` and re-exports them afterward so they always win. If you're seeing this, confirm you `export`ed the variable (not just set it) before invoking the script. |
| Two checkouts fight over the same containers/volumes | `docker compose up` reuses `rumi-postgres`/`rumi-synapse`/`rumi-element` from a different checkout | Set distinct `COMPOSE_PROJECT_NAME` **and** `RUMI_CONTAINER_PREFIX` in each checkout's `deploy/.env` (they don't have to match each other) -- see the comments in `deploy/.env.example`. |
| `e2e.sh` prints a Python traceback instead of a FAIL line | (should not happen -- if it does, it's a regression) | Every JSON access in `e2e.sh` goes through `json_field`/`json_list_contains`/`json_chunk_has_body`, which catch parse errors and return an empty/0 default. A raw traceback means a check was added that bypasses those helpers -- route it through them instead. |
| `welcome.html` or `home.html` shows a literal `__SERVER_NAME__` | curling `/welcome.html` doesn't show a `#/register` link, or `/home.html` doesn't show `@rumi:<server>` | You're looking at `deploy/element/welcome.template.html`/`home.template.html` directly, or `setup.sh` didn't run. The non-`.template` files are gitignored, rendered output -- re-run `scripts/setup.sh`, which renders both fresh every time (step 8) and force-recreates `element` so the container picks them up. |
| Synapse container never reports healthy | `docker compose ps` shows `synapse` stuck `starting` past ~40s | Check `scripts/logs.sh -s synapse` for a config or Postgres-connection error. The healthcheck hits `http://localhost:8008/health` inside the container -- if Postgres itself isn't healthy yet, Synapse won't start (Compose's `depends_on: condition: service_healthy` should prevent this, but a manual `docker compose up -d synapse` without `postgres` running first will hit it). |
| `docker compose logs` shows plain text, not JSON, for Synapse | Missing `/data/rumi_log_format.py` or stale `homeserver.yaml`/log config from before this stack's setup | Re-run `scripts/setup.sh` -- step 4 regenerates `rumi_log_format.py` and the log config idempotently even if `homeserver.yaml` already exists. |
