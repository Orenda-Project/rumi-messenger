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

## Stale devices, and why a teacher's phone can suddenly stop sending

A device that never uploaded encryption keys stays on the account forever: an API login, a
half-finished sign-in, a browser tab closed mid-way. Once the owner verifies her identity, the app
refuses to hand room keys to any device she has not signed, so every encrypted send from her new
phone fails with a red mark and no explanation. We hit exactly this on 23 September, see
[#14](https://github.com/Orenda-Project/rumi-messenger/issues/14); the app's own log said
`one or more verified users have unsigned devices`.

```bash
scripts/devices.sh list  +923360506129          # every device, name, last seen
scripts/devices.sh prune +923360506129          # remove unnamed devices that never synced; asks first
scripts/devices.sh prune +923360506129 --yes    # same, unattended
```

`prune` only touches devices with no display name that have never synced, which is what a keyless
ghost looks like. A real phone or browser has both and is never removed. Run `list` first if unsure.
After a prune, the teacher retries the failed message in the app; it goes through without signing in again.

## Teacher directory search ("start chat" finds a colleague by name)

[#10](https://github.com/Orenda-Project/rumi-messenger/issues/10): before this, a teacher had to
know a colleague's exact Matrix id (`@+923001234567:yourserver.org`) to start a chat -- there was
no "type a name" search. `scripts/setup.sh` now enables Synapse's own user directory and Element
X's "Start a chat with a colleague" flow searches it directly; nothing in Element itself needed
changing.

**Config** (`scripts/setup.sh`, Step 3, `homeserver.yaml`):

```yaml
user_directory:
  enabled: true
  search_all_users: true
  prefer_local_users: true
```

Keys and defaults are Synapse's own (`enabled` defaults to `true`; `search_all_users` and
`prefer_local_users` both default to `false`) -- see [Synapse's config
docs](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#user_directory).
`search_all_users: true` is deliberate for a closed school server: every account here comes from
admin-created teacher onboarding (`scripts/teacher.sh`, below) or the `registration_shared_secret`
flow, never open public signup, so there's no untrusted stranger to hide a teacher from.

**Reindexing an existing server.** Synapse's own docs warn: enabling `search_all_users` on a server
whose directory indexes were last built before Synapse 1.44 requires a rebuild, or older/renamed
users won't be searchable. `scripts/setup.sh` handles this automatically and idempotently: on first
run after this change it fires the documented admin API job once --

```bash
curl -s -X POST "http://127.0.0.1:8108/_synapse/admin/v1/background_updates/start_job" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"job_name":"regenerate_directory"}'
```

(see [Synapse's Background Updates admin
API](https://element-hq.github.io/synapse/latest/usage/administration/admin_api/background_updates.html#run))
-- then drops a marker file, `deploy/synapse/data/.user_directory_reindexed`, so reruns of
`setup.sh` never repeat the job (it's a full flush-and-rebuild over every local user; harmless but
pointless to redo on every invocation on a bigger school server). Delete that marker file to force
a re-run, e.g. after bulk-importing teachers some other way that bypasses `scripts/teacher.sh`.
This is async on Synapse's side; check progress via the [Background Updates admin
API](https://element-hq.github.io/synapse/latest/usage/administration/admin_api/background_updates.html)
if a very large import doesn't show up in search right away. New accounts created one at a time
(via `teacher.sh` or normal registration) do NOT need this -- verified live: a brand-new account
was searchable by name within seconds, no manual reindex needed (see `scripts/e2e.sh`).

**Onboarding a teacher with a real name** (so they show up as "Ayesha Khan", not a bare phone
number):

```bash
scripts/teacher.sh add "+923001112233" "Ayesha Khan"                       # generates a password
scripts/teacher.sh add "+923004445566" "Bilal Ahmed" --password teacher1234  # or set your own
scripts/teacher.sh add "+923001112233" "Ayesha Khan"                       # rerun: updates display
                                                                            # name only, password
                                                                            # untouched, never fails
```

Verified live against this stack:

```bash
curl -s -X POST "http://127.0.0.1:8108/_matrix/client/v3/user_directory/search" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"search_term":"Ayesha","limit":10}'
# -> {"limited": false, "results": [{"user_id": "@+923001112233:localhost",
#     "display_name": "Ayesha Khan", "avatar_url": null}]}
```

...and confirmed in Element Web itself: opening "Direct Messages" and typing "Ayesha" filters the
Suggestions list down to exactly `Ayesha Khan @+923001112233:localhost` -- both teachers created by
`teacher.sh` also appeared as suggestions before typing anything, since Element pre-populates that
list from the user directory too.

**Search behavior, so you don't file it as a bug**: it's a per-word PREFIX match (verified live),
not an arbitrary substring search -- `"Tea"` finds a user whose display name contains `"Teacher"`,
but `"eacher"` (missing the leading `T`) does not. This matches how a "type a few letters" UI is
actually used; a mid-word substring engine is not needed here.

**Privacy** (read before ever putting more than one school on one server): with
`search_all_users: true`, EVERY account on this homeserver can find every other account by name --
there is no per-school boundary. For the current deployment shape (one Synapse instance per
school), this is moot: "all users on this server" and "all teachers at this school" are the same
set, so there's nothing to leak. It stops being moot the moment a second school is put on the same
homeserver to save infra cost -- at that point teachers from School A could search up and message
teachers at School B, which is very likely not what either school agreed to. If that ever happens,
do NOT leave `search_all_users: true` as-is; the two real options are (a) keep one Synapse instance
per school (simplest, what this stack assumes today), or (b) if a genuinely shared multi-tenant
server is required, set `search_all_users: false`, stop auto-joining every account into the single shared `#rumi-announcements`
(one announcements room per school instead; today's shared room alone makes every account discoverable to
every other regardless of the flag, which a reviewer proved by disabling the flag and watching search still
succeed), and give each school its own
[Space](https://element-hq.github.io/synapse/latest/user_directory.html) so cross-school search
results are suppressed the same way room-shared/public-room visibility already limits them when
this flag is off. This repo does not implement (b) -- it isn't needed yet, and building it before a
second school exists would be speculative.

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

Writes `backups/<UTC timestamp>/postgres.sql` (a `pg_dump` of the `synapse` database),
`backups/<UTC timestamp>/media_store.tar.gz` (everything under
`deploy/synapse/data/media_store`), and `backups/<UTC timestamp>/<SERVER_NAME>.signing.key` (the
homeserver's identity key -- losing it without a backup means every client has to re-verify from
scratch, same blast radius as losing Postgres). Then **restore-verifies itself**: spins a
throwaway, fully isolated scratch Postgres container (no shared volume/network with the real
stack), restores the just-written `postgres.sql` into it, counts rows in `users`, and tears the
scratch container down -- proof the dump is a real, loadable database, not just non-empty bytes.
Finally prunes `backups/` down to the newest `BACKUP_KEEP_N` timestamped folders (`deploy/.env`,
default 14). Pass `--skip-verify` to skip the restore-verification step (e.g. a very large media
store where you just want "did the files get written").

Verified live on this stack (real numbers from a real run, not illustrative):

```
[backup] dumping postgres -> backups/20260923T165719Z/postgres.sql
[backup] archiving media_store -> backups/20260923T165719Z/media_store.tar.gz
[backup] copying signing key(s) -> backups/20260923T165719Z/
[backup] done: backups/20260923T165719Z
[backup] restore-verify: starting scratch postgres (rumi-backup-verify-20260923T165719Z)
[backup] restore-verify: waiting for scratch postgres to accept connections
[backup] restore-verify: loading backups/20260923T165719Z/postgres.sql into scratch postgres
[backup] RESTORE VERIFIED: users table has 182 row(s) after restoring this backup into a scratch database
[backup] rotation: 3 backups on disk, under BACKUP_KEEP_N=14, nothing to remove
```

**Restore into the real stack** (not scripted -- do this deliberately, and stop Synapse first;
`scripts/backup.sh` above already proves the dump itself restores cleanly, this is the separate,
deliberate step of putting it back into production):

```bash
cd deploy
docker compose stop synapse

# Postgres
cat ../backups/<timestamp>/postgres.sql | docker compose exec -T postgres psql -U synapse -d synapse

# Media store (as root inside a throwaway container, same reasoning backup.sh uses --
# media_store is owned by uid 991 inside the synapse container)
docker run --rm -v "$(pwd)/synapse/data:/data" -v "$(pwd)/../backups/<timestamp>:/backup:ro" \
  alpine sh -c 'rm -rf /data/media_store && tar -xzf /backup/media_store.tar.gz -C /data'

# Signing key (only if it was ever lost/corrupted -- restoring it when the live one is still
# fine and DIFFERENT will break every existing client's trust of this server's identity)
docker run --rm -v "$(pwd)/synapse/data:/data" -v "$(pwd)/../backups/<timestamp>:/backup:ro" \
  alpine sh -c 'cp /backup/*.signing.key /data/ && chown 991:991 /data/*.signing.key && chmod 600 /data/*.signing.key'

docker compose start synapse
```

A restore replaces live data with the backup's -- anything sent between the backup and the
restore is gone. There's no partial/incremental restore here; back up on a schedule if you need
finer recovery points.

**Scheduling** -- nightly via cron (add with `crontab -e`; adjust the repo path):

```cron
0 3 * * * cd /path/to/rumi-messenger && scripts/backup.sh >> /var/log/rumi-backup.log 2>&1
```

or as a systemd timer (`/etc/systemd/system/rumi-backup.service` + `.timer`):

```ini
# rumi-backup.service
[Unit]
Description=Rumi Messenger backup

[Service]
Type=oneshot
WorkingDirectory=/path/to/rumi-messenger
ExecStart=/path/to/rumi-messenger/scripts/backup.sh
```

```ini
# rumi-backup.timer
[Unit]
Description=Nightly Rumi Messenger backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

`systemctl enable --now rumi-backup.timer`. `BACKUP_KEEP_N` (`deploy/.env`) bounds disk usage --
raise it if you want more history than the default 14 days at a nightly cadence.

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
scripts/theme-guard.sh      # before and after Element bumps: verify Compound design tokens still match
```

Never move a tag back to `:latest` -- it defeats the whole point of pinning (see
`docs/DECISIONS.tsv`, 2026-09-21).

## Moving to a real domain (TLS)

By default Synapse and Element bind to `127.0.0.1` only -- nothing is reachable off the host. To
serve a real domain with TLS, use the `prod` Compose profile (older alias: `tls` -- same service,
kept for back-compat), which brings up Caddy (`deploy/Caddyfile`) as the front door:

```bash
# in deploy/.env:
SERVER_NAME=chat.yourschool.org
PUBLIC_BASE_URL=https://chat.yourschool.org
# PUBLIC_DOMAIN / ELEMENT_DOMAIN default from SERVER_NAME -- leave them unset unless you
# deliberately want Element Web on a different subdomain (see deploy/.env.example).
# BIND_ADDR stays 127.0.0.1 -- see the correction below, this is NOT the "make it public" switch.

cd deploy
docker compose --profile prod up -d
```

**Do NOT set `BIND_ADDR=0.0.0.0` to "make it public".** Caddy reaches Synapse and Element over
the internal Docker network by service name (`synapse:8008`, `element:80`), never through their
host-published ports -- widening `BIND_ADDR` only adds a second, unprotected way to reach them
that skips Caddy's TLS termination and rate limiting entirely. `BIND_ADDR=127.0.0.1` is correct
in production, not just for local testing; Caddy's own `80`/`443` (docker-compose.yml, always
published on every interface once the profile is up) are the only ports that need to be reachable
from the internet. `scripts/prod-check.sh` (below) asserts this.

`SERVER_NAME` is baked into every Matrix user id and room alias **at homeserver-generation
time** -- if you already ran `setup.sh` with `SERVER_NAME=localhost`, changing it later means
regenerating the homeserver (`scripts/reset.sh`, then `setup.sh` again with the real domain) --
existing accounts on `localhost` don't carry over. Decide your real domain before you invite real
teachers.

Caddy handles `/.well-known/matrix/server` and `/.well-known/matrix/client` for you (see
`deploy/Caddyfile`), so clients can discover your homeserver from just the domain, and gets you
automatic TLS via Let's Encrypt as long as ports 80/443 are reachable from the internet for the
ACME challenge.

**Proving the TLS path with no domain yet** -- set `CADDY_TLS_MODE=internal` in `deploy/.env`
before bringing the `prod` profile up: Caddy then mints its own self-signed cert instead of
trying (and failing) real ACME, so the whole reverse-proxy/well-known/TLS-handshake path can be
proven on a machine with no public DNS. Verified live against this exact repo's dev stack:

```
$ grep -E '^(PUBLIC_DOMAIN|ELEMENT_DOMAIN|CADDY_TLS_MODE)=' deploy/.env
PUBLIC_DOMAIN=localhost
ELEMENT_DOMAIN=localhost
CADDY_TLS_MODE=internal

$ curl -sk --resolve localhost:443:127.0.0.1 https://localhost/.well-known/matrix/server
{"m.server": "localhost:443"}
```

Never leave `CADDY_TLS_MODE=internal` set once a real domain exists -- browsers refuse a
self-signed cert (`-k`/an explicit "proceed anyway" click is the only way past it), which is
exactly what marks it as a local-only proof.

### `scripts/prod-check.sh` -- the falsifiable version of "is this actually hardened"

Asserts the safety posture above against a **running** stack: TLS/well-known actually served,
registration closed, Postgres/Synapse/Element not directly exposed, coturn hardening
(`no-tcp-relay`, `denied-peer-ip`) applied, `enable_metrics` off, `deploy/.env` gitignored.

```bash
scripts/prod-check.sh
```

Several checks are **supposed** to fail against the plain dev stack (no Caddy, open
registration) -- that's what makes this a real check and not a script that always prints PASS.
Verified live on this repo: 6/11 failing with the `prod` profile down, 10/11 passing once it was
brought up with `CADDY_TLS_MODE=internal` (the one still-failing check, registration, is real --
`REGISTRATION_MODE` on this dev stack is deliberately left `open` for testing; flip it to `token`
before inviting real teachers, see "Registration modes" below).

## Calls (1:1 audio/video, issue #1)

Element's built-in call button works out of the box between two browser tabs on the same
machine -- that is not evidence it works between two real devices. Two devices behind separate
home routers or mobile NAT almost always cannot reach each other directly for the actual audio/
video media stream (only the signalling -- who's calling whom -- goes through Synapse); a TURN
server relays that media. This stack runs one: `coturn` (`deploy/docker-compose.yml`), configured
by `scripts/setup.sh` from `deploy/coturn/turnserver.conf` (gitignored, rendered fresh every run),
using the TURN REST API mechanism -- Synapse and coturn share one secret (`TURN_SHARED_SECRET` in
`deploy/.env`) and each independently derive the same short-lived, per-call username/password from
it (`turn_shared_secret` in `homeserver.yaml` / `static-auth-secret` in `turnserver.conf` -- see
[docs/ARCHITECTURE.md's "Calls" section](ARCHITECTURE.md#calls-the-turn-relay-coturn-and-the-shared-secret-credential-mechanism)
for the full mechanism, why Synapse's `turnServer` response alone can't prove coturn is alive, and citations).

### Ports that must be reachable, and why UDP matters

| Port(s) | Protocol | Purpose |
|---|---|---|
| `TURN_PORT` (3478 default) | TCP + UDP | STUN/TURN signalling: client asks coturn to allocate a relay |
| `TURN_MIN_PORT`-`TURN_MAX_PORT` (49152-65535 default) | **UDP only** | The actual relayed call media -- one dedicated port per active call leg |

Both a teacher's Element client AND coturn need **UDP** reachable end to end for the relay
ports, not just the signalling port on 3478. WebRTC media is UDP because it's real-time (a
retransmitted late video frame is useless) -- a network that allows TCP but blocks UDP (some
locked-down school/office firewalls do exactly this) will let the call connect and then produce
no audio/video, which looks like a broken app rather than a blocked port. This is also why coturn
runs with `network_mode: host` instead of this file's usual bridge-plus-port-mapping style: Docker
publishing all ~16k of those UDP ports individually is what coturn's own documentation warns
against (`docs/DECISIONS.tsv`).

### Local testing vs. a real deployment

`BIND_ADDR=127.0.0.1` (this stack's default, same as Synapse/Element) makes coturn's
`listening-ip` loopback-only -- calls placed between two browser tabs on the same machine will
allocate and relay successfully (you can prove the mechanism works, see below), but **this is
USELESS for a real call between two different devices**, for the same reason a Synapse bound to
127.0.0.1 is useless for a real cross-device chat: nothing outside the host can reach it. This is
not a bug to route around locally -- it's the same safe-by-default posture as the rest of this
stack (see "Moving to a real domain (TLS)" above), and going live with real calling needs that
same production-hardening work, tracked in **issue #6**: a real public IP/domain, `BIND_ADDR=0.0.0.0`,
and -- specifically for coturn -- setting `TURN_EXTERNAL_IP` in `deploy/.env` so coturn tells
clients the address actually reachable from off-host (see the comment above that var in
`deploy/.env.example`; a coturn behind NAT that doesn't advertise its public IP will hand clients
a private, unreachable relay address).

Also a known, explicit gap until issue #6: coturn currently runs `no-tls` (plaintext TURN/STUN,
no TLS/DTLS listener) -- see the comment above `no-tls` in `scripts/setup.sh`'s coturn config
step for why (a separate certificate from Synapse/Element's, since a browser's WebRTC stack talks
to coturn directly, not through Caddy).

### How to verify a real call actually works

There is no way to prove real NAT traversal between two independent networks from one machine --
that is a fundamental limitation of testing this from a single host, not a gap in the setup. What
can be verified locally (and is, by `scripts/e2e.sh`):

```bash
scripts/e2e.sh   # includes: GET /_matrix/client/v3/voip/turnServer returns real, non-empty
                 # TURN credentials (uris/username/password/ttl) for a real logged-in user
```

and, directly against coturn itself (proves the server is listening and answering, not just that
Synapse is configured to point at it):

```bash
docker exec rumi-coturn turnutils_stunclient -p 3478 127.0.0.1
# -> "IPv4. UDP reflexive addr: 127.0.0.1:<port>" means coturn answered a real STUN binding request
```

Neither of those places an actual call or proves two different devices can reach each other. The
one test that does needs a human, on two genuinely separate networks (e.g. your home WiFi and
your phone's mobile data with WiFi off, not two devices on the same router):

1. Deploy with `BIND_ADDR=0.0.0.0`, a real domain, and `TURN_EXTERNAL_IP` set (see above).
2. Sign in as two different accounts on the two devices, on two different networks.
3. Open a DM, start a call, and confirm audio/video actually flows both ways -- not just that
   the call connects (a connected-but-silent call is the exact symptom of the "UDP blocked"
   failure mode described above).

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

## Rumi's replies show a red "unverified device" shield (issue #15)

Cause: the bot (matrix-bot-sdk 0.8.0) never creates cross-signing keys, so its device is
"not verified by its owner" and Element draws a red shield on every reply. The bot cannot fix
this itself (its RustEngine throws on the SignatureUpload/KeysBackup requests cross-signing
needs), so it is done out-of-band, once, without touching the bot process:

```bash
scripts/bot-cross-sign.sh          # @rumi, RUMI_BOT_PASSWORD, device of the token in deploy/rumi-channel.env
```

What it does: logs in as @rumi on a *temporary* matrix-js-sdk device, creates secret storage
(recovery key written to `deploy/rumi-cross-signing-recovery-key.txt`, chmod 600, gitignored),
creates the cross-signing keys, signs the bot's existing device with the self-signing key, then
logs the temporary device out. No bot restart; `.matrix-storage`, the bot's token and its device
are never touched. Re-running is a no-op once the device is signed. If the bot ever gets a new
device/token, just re-run: it reloads the keys from secret storage with the recovery key and
signs the new device. **Back up the recovery key file** -- without it the script refuses to run
again (re-creating keys would be an identity reset, which teachers see as "Rumi's identity changed").

Check it worked (any teacher token):

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8108/_matrix/client/v3/keys/query \
  -d '{"device_keys":{"@rumi:localhost":[]}}'
# master_keys + self_signing_keys present for @rumi, and the bot device's "signatures" include
# the ed25519 self-signing key id next to its own ed25519:<DEVICE> key.
```

Stale @rumi devices: `scripts/devices.sh list rumi` also shows old devices from
earlier bot runs. They were deliberately **not** pruned for #15: none of them ever uploaded device
keys (only the live device appears in `/keys/query`), so no client can see them as "unsigned
devices" and they have no effect on the shield. `devices.sh prune rumi` would only remove the one
never-seen device anyway; leave the others unless a separate cleanup is agreed.

Done and verified 23 Sep 2026: Rumi's replies went from RED (unsigned device) to no shield, both via
the js-sdk `getEncryptionInfoForEvent` check and in Element Web.

## Rate limits

Synapse's rate limits live in `homeserver.yaml` under the `rc_*` keys (`rc_message`,
`rc_login`, `rc_joins`, `rc_invites`, etc.). **`scripts/setup.sh` does NOT ship Synapse's own
defaults here** (an earlier version of this doc said it did -- corrected, issue #6): Synapse's
public-server-facing defaults are tight enough that our own testing tripped the login limiter
repeatedly (a staffroom signing in together at 8am, or a class joining a room together, reads as
abuse at those defaults), so `setup.sh` Step 3 sets school-shaped values instead --
`rc_login`/`rc_joins`/`rc_message`/`rc_invites` all raised from Synapse's defaults, see the
comments right above those keys in `scripts/setup.sh` for the exact numbers and reasoning. If you
need to change them further (e.g. a bulk-import script still tripping a limit while creating many
accounts at once), edit `deploy/synapse/data/homeserver.yaml` directly and restart:

```bash
cd deploy && docker compose restart synapse
```

Full key reference: [Synapse's rate-limiting
docs](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#ratelimiting).

## Federation and message retention (issue #8)

Decided 2026-09-23, see [FEDERATION-RETENTION.md](FEDERATION-RETENTION.md) for the reasoning.

- **Federation is OFF.** `scripts/setup.sh` sets `federation_domain_whitelist: []` and removes the
  `federation` resource from the listener, so `/_matrix/federation/*` is not served at all
  (`scripts/e2e.sh` asserts it answers 404). Teachers can only reach accounts on this server.
  To talk to a second school later: list its domain in `federation_domain_whitelist`, add
  `federation` back to the listener resources (or a dedicated 8448 listener behind TLS), and
  rerun `scripts/setup.sh`.
- **Message retention is indefinite** (Synapse default, no `retention` block). Nothing to run.
  Revisit if Postgres grows past ~500 GB; the config to add is in FEDERATION-RETENTION.md.

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
| `GET /_matrix/client/v3/voip/turnServer` returns `{}` | Synapse's config has `turn_uris` (check with an admin `docker compose exec synapse cat /data/homeserver.yaml`), but the endpoint still answers empty | Synapse only reads homeserver.yaml at process start -- it does not hot-reload TURN config. `scripts/setup.sh` step 6 now restarts synapse after every homeserver.yaml patch specifically because of this (discovered live building the calling feature); a manual homeserver.yaml edit still needs `docker compose restart synapse` per the "Rate limits" section above. |
| coturn logs `WARNING Bad configuration format: no-dtls` on startup | (cosmetic, not fatal -- coturn still starts and works) | Would indicate a stale `deploy/coturn/turnserver.conf` from before this repo's coturn 4.18.0 pin -- that version removed the `no-dtls` directive (DTLS is opt-in via a separate `--dtls` flag, off by default). Re-run `scripts/setup.sh`, which renders a fresh `turnserver.conf` without it every time. |
| `docker compose up -d coturn` doesn't pick up a `turnserver.conf` change | `docker logs rumi-coturn` shows a config from before your edit, or (worse) `WARNING NO EXPLICIT LISTENER ADDRESS(ES) ARE CONFIGURED` binding every interface instead of `BIND_ADDR` | Same stale-container-after-rewriting-a-mounted-file issue Element already had (see the `welcome.html`/`home.html` row above) -- `scripts/setup.sh` force-recreates `coturn` every run for exactly this reason (discovered live: coturn ran for 2+ minutes on a config it couldn't even read after a plain `up -d` no-op'd). If you edit `turnserver.conf` by hand outside `setup.sh`, run `docker compose up -d --force-recreate coturn` yourself, not a plain `up -d`. |
| coturn's `turnserver.conf` can't be rewritten on a rerun | `scripts/setup.sh` fails with `Permission denied` writing `deploy/coturn/turnserver.conf` | Expected and handled: a prior run `chown`'d the file to coturn's fixed runtime uid (65534, "nobody") and `chmod 600`'d it so the container can read a secret it doesn't own the host-side copy of. `setup.sh` `rm -f`s the file before re-rendering (removing a file only needs write access to its *directory*, which your host user does own) -- if you see this error, something removed that `rm -f` step. |

## Going live on a real domain (issue #6 -- the actual checklist)

Everything above (`prod`/`tls` profile, `scripts/prod-check.sh`, `scripts/backup.sh`) has been
proven **locally**, with `CADDY_TLS_MODE=internal` standing in for a real domain -- see each
section above for the exact commands and output. What's proven vs. what genuinely needs a real
domain/server, and can't be faked from this machine:

**Proven here, ready to use as-is:**
- Caddy (`prod`/`tls` profile) terminates TLS and serves `.well-known/matrix/{server,client}`
  correctly, driven entirely by `PUBLIC_DOMAIN`/`ELEMENT_DOMAIN`/`CADDY_TLS_MODE` in `deploy/.env`.
- `BIND_ADDR=127.0.0.1` keeps Synapse/Element/Postgres off the network with Caddy still able to
  reach them (the RUNBOOK's own earlier "set BIND_ADDR=0.0.0.0" advice was wrong and is now
  corrected above).
- coturn hardening: `no-tcp-relay` (always on) and `denied-peer-ip` for private/loopback ranges
  (once `BIND_ADDR` is public) -- `scripts/setup.sh` Step 5.
- `scripts/backup.sh` produces a dated, rotated, **restore-verified** backup (Postgres + media +
  signing key) -- proven end to end against this repo's real dev data (182 `users` rows restored
  into a scratch database).
- `scripts/prod-check.sh` catches real regressions -- verified live to FAIL 6/11 checks on the
  plain dev stack and PASS 10/11 once `prod`/`tls` was up with `CADDY_TLS_MODE=internal` (the one
  remaining fail, open registration, is real and expected -- see below).

**Needs a real domain/server to actually finish (can't be proven from a laptop):**
- A publicly trusted TLS cert -- `CADDY_TLS_MODE=internal`'s self-signed cert proves the mechanism,
  not the cert; real ACME needs ports 80/443 reachable from the internet.
- `TURN_EXTERNAL_IP` for coturn behind NAT, and a real cross-device call (no way to prove NAT
  traversal between two independent networks from one host -- see the "Calls" section above).
- Flipping `REGISTRATION_MODE=open` to `token` and minting real tokens for a school's staff
  (`docs/RUNBOOK.md`'s "Registration modes" section has the admin-API command) -- left `open` on
  this repo's own dev stack deliberately, since flipping it would break existing local/e2e testing
  flows that assume open registration; a real deployment should decide this before inviting
  teachers.
- Deciding and setting real media retention (see "Media retention" above) and a disk-size budget
  once real upload volume exists.

### DNS records to create

| Record | Type | Points to | Why |
|---|---|---|---|
| `PUBLIC_DOMAIN` (e.g. `chat.yourschool.org`) | A / AAAA | your server's public IP | Matrix identity, `.well-known`, federation (if ever enabled) |
| `ELEMENT_DOMAIN` (only if different from `PUBLIC_DOMAIN`) | A / AAAA | same server (or a separate one fronting it) | Element Web's own address |

If `PUBLIC_DOMAIN == ELEMENT_DOMAIN` (the default, and the common case -- one address doing
everything), you only need the one record.

### Ports to open on the server's firewall / cloud security group

| Port(s) | Protocol | Service | Notes |
|---|---|---|---|
| 80 | TCP | Caddy | ACME HTTP-01 challenge + HTTP->HTTPS redirect |
| 443 | TCP | Caddy | Matrix client/federation API + Element Web, all through Caddy |
| 8448 | TCP | -- | Only if federation is ever turned on (currently OFF, issue #8) -- not needed for this deployment shape |
| `TURN_PORT` (3478 default) | TCP + UDP | coturn | STUN/TURN signalling |
| `TURN_MIN_PORT`-`TURN_MAX_PORT` (49152-65535 default) | **UDP only** | coturn | Relayed call media -- see "Calls" section above for why this must be UDP, not just the signalling port |

Do **not** open Synapse's `SYNAPSE_PORT`, Element's `ELEMENT_PORT`, or Postgres's `5432` directly
-- they should never be reachable except through Caddy / the Docker-internal network. Run
`scripts/prod-check.sh` after opening ports to confirm this is still true from the outside, not
just from `localhost`.

### First-run sequence on the real server

1. Point DNS at the server (above); confirm it resolves before continuing (`dig +short
   PUBLIC_DOMAIN`).
2. `git clone` this repo, `cd deploy`.
3. Set in `deploy/.env` (or export before running `setup.sh`, same effect): `SERVER_NAME`,
   `PUBLIC_BASE_URL=https://<PUBLIC_DOMAIN>`, `REGISTRATION_MODE=token`. Leave `BIND_ADDR` at its
   default `127.0.0.1` and `CADDY_TLS_MODE` unset (real ACME).
4. `scripts/setup.sh` (brings up Postgres/Synapse/Element/coturn, generates the homeserver).
5. `docker compose --profile prod up -d` (brings up Caddy; first run does the real ACME
   handshake -- watch `scripts/logs.sh -s caddy` for "certificate obtained successfully").
6. `scripts/prod-check.sh` -- every check should now PASS, including registration (confirm
   `REGISTRATION_MODE=token` took effect) and the TLS/well-known checks (now against a real,
   publicly trusted cert instead of `-k`).
7. Mint a registration token and onboard the first real teacher accounts
   (`scripts/teacher.sh`, "Registration modes" section above).
8. Put `scripts/backup.sh` on the cron/systemd-timer schedule above.
9. If real cross-device calling is needed: set `TURN_EXTERNAL_IP`, re-run `setup.sh`, and have two
   people on two different networks actually place a call -- the one thing that can't be verified
   from the server alone.
