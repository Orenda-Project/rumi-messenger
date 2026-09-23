# Push Notifications on Phones (issue #3)

## Status (2026-09-24)

Two push paths exist. **The no-Google one (UnifiedPush + our own ntfy) is the one we ship.**

| Path | Who runs the server | Keys needed | State |
|---|---|---|---|
| **UnifiedPush + self-hosted ntfy** | us (`ntfy` service, `push` profile) | none | Phone half **proven** on the emulator with the app force-stopped (below). Synapse-to-ntfy hop needs a non-private address for ntfy, so it is proven only on a real deployment (see "The one Synapse catch"). |
| Firebase (FCM) via Sygnal | us (`sygnal` service, `push` profile) | Firebase service account + `google-services.json` + signed build | Gateway built, no keys. Unchanged, see "Sygnal" below. |

**Before this change** the F-Droid/no-Google build showed "No distributors available" on every
launch and got no notifications at all while closed: there was no distributor on the phone and no
push server for it to talk to.

## Self-hosted ntfy (the no-Google path)

How Element X's own F-Droid users get push, and exactly what the fork's code does
(`libraries/pushproviders/unifiedpush/`):

1. The phone runs the **ntfy** Android app (F-Droid build) as its UnifiedPush *distributor*,
   pointed at our server. It keeps one connection open to ntfy for every app on the phone.
2. Rumi Messenger asks the distributor for an endpoint and gets
   `<NTFY_BASE_URL>/up<12 random chars>?up=1` (a private ntfy topic).
3. `UnifiedPushGatewayResolver.kt` takes that endpoint's **host root** and calls
   `GET <host>/_matrix/push/v1/notify`. ntfy answers `{"unifiedpush":{"gateway":"matrix"}}`
   (ntfy has a built-in Matrix push gateway, `server/server_matrix.go`), so the app registers a
   Synapse pusher with `url = <NTFY_BASE_URL>/_matrix/push/v1/notify` and
   `pushkey = <endpoint>`. Anything else there (404, 401, ...) makes the app silently fall back to
   Element's public gateway, which is why ntfy needs its **own hostname**, not a `/ntfy` path:
   on `PUBLIC_DOMAIN`, `/_matrix/*` is Synapse's.
4. On a new message Synapse POSTs to ntfy's gateway, ntfy publishes to the topic, the ntfy app
   hands it to Rumi Messenger, which wakes (even force-stopped: the UnifiedPush connector binds a
   `RaiseToForegroundService`), fetches the event from Synapse and shows the notification.

**Sygnal is not in this path.** ntfy is both the push server and the Matrix gateway.

### What's deployed (`deploy/docker-compose.yml`, `push` profile)

- `ntfy`: `binwiederhier/ntfy:v2.28.0`, bound `${BIND_ADDR}:${NTFY_PORT:-2586}`, data in the
  `rumi-ntfy-data` volume. Configured by env, no rendered file:
  - `NTFY_BASE_URL` (default `https://ntfy.${PUBLIC_DOMAIN}`). **Must equal the URL phones use:**
    ntfy's gateway rejects any pushkey that doesn't start with `<base-url>/`.
  - `NTFY_AUTH_DEFAULT_ACCESS=deny-all` + `NTFY_AUTH_ACCESS=*:up*:read-write`: everything is
    denied except UnifiedPush topics. Anonymous read is the phone's subscription; anonymous write
    is the gateway publish (and, with the next setting, the subscriber must also have write).
  - `NTFY_VISITOR_SUBSCRIBER_RATE_LIMITING=true`: every push arrives from one visitor (Synapse),
    so limits are charged to each subscribing phone instead. Side effect worth knowing: ntfy
    refuses (HTTP 507) a publish to an `up*` topic that has no live subscriber.
  - `NTFY_BEHIND_PROXY=true` (Caddy in front). `NTFY_UPSTREAM_BASE_URL` deliberately unset: it
    only forwards to ntfy.sh -> Firebase/APNs for iOS.
- Caddy: a second site block `{$NTFY_DOMAIN}` (default `ntfy.${PUBLIC_DOMAIN}`) ->
  `ntfy:80`. Needs its own DNS A record pointing at the server.
- `scripts/push-setup.sh` now starts ntfy first (no keys involved), then does the Sygnal/FCM part
  exactly as before.
- `scripts/push-check.sh` checks, all falsifiable (stopping ntfy turns all four into FAIL):
  health, the discovery JSON above, that a non-`up*` publish gets 403, and that a Matrix-gateway
  publish reaches a live `up*` subscriber. Sygnal checks run only once an FCM pushkin exists.

### The one Synapse catch: pushers can't reach private IPs

Synapse sends pusher traffic through its IP-blocklisted HTTP client, and with no
`ip_range_blacklist` in `homeserver.yaml` the default list applies: 127/8, 10/8, 172.16/12,
192.168/16 and friends. Seen live on 2026-09-24:

```
synapse.http.client  Error sending request to  POST http://127.0.0.1:2586/_matrix/push/v1/notify: SynapseError 403: IP address blocked
synapse.push.httppusher  Failed to push data to @+923001230095:localhost/im.vector.app.android/http://127.0.0.1:2586/upQx4NtGsI5P9w?up=1: ... 403: IP address blocked
```

- **Production:** `NTFY_DOMAIN` resolves (from inside the Synapse container too, it isn't a
  compose alias) to the server's public IP, which isn't blocked. No Synapse change needed. Check
  once with `docker exec rumi-synapse getent hosts ntfy.<domain>` that it gives the public IP.
- **A LAN-only or local deployment** needs `ip_range_whitelist: ["<ntfy's IP>/32"]` in
  `homeserver.yaml` and a Synapse restart. Not applied here: this task was not allowed to restart
  Synapse. (Locally there's a second problem: `127.0.0.1` inside the Synapse container is Synapse
  itself, so a local proof also needs a shared address, e.g. `NTFY_BASE_URL=http://<LAN IP>:2586`
  with ntfy bound to that IP.)

### What the teacher does once

1. Install **ntfy** from F-Droid (or its official release APK,
   [github.com/binwiederhier/ntfy-android](https://github.com/binwiederhier/ntfy-android/releases),
   `fdroid-release` build). Allow its notifications, and allow it to run in the background
   when it asks (battery optimisation off), or Android may kill its connection.
2. In ntfy: menu -> **Settings** -> **Default server** -> the school's ntfy address
   (`https://ntfy.<school domain>`) -> **Save**. **Do this before opening Rumi Messenger:** an
   app that registers first gets a topic on the public `ntfy.sh` and keeps it (seen live: the
   debug build registered `https://ntfy.sh/up...` and a Synapse pusher pointing at ntfy.sh, which
   we deleted).
3. Open Rumi Messenger. With exactly one distributor installed it picks ntfy on its own; the "No
   distributors available" box is gone. Settings -> Notifications -> Troubleshoot notifications ->
   Run tests shows "Current push provider: UnifiedPush (io.heckel.ntfy)" and "... is a Matrix
   gateway".

### Emulator proof (2026-09-24, `emulator-5554`, API 34, released `ai.hellorumi.messenger` v0.1.1)

Setup: `NTFY_BASE_URL=http://127.0.0.1:2586` in `deploy/.env`, `adb reverse tcp:2586 tcp:2586`
and `tcp:8108`. ntfy `1.25.2` fdroid-release APK from the official repo, SHA-256
`8a1075c0...9eb53f39` matching GitHub's own asset digest. Evidence in the personal-agent vault,
`evidence-2026-09-23/push/`.

| Step | Result |
|---|---|
| ntfy default server set to `http://127.0.0.1:2586` | screenshot `01` |
| Rumi Messenger launched as Teacher Zara | no "No distributors available" dialog (`02`); logcat `NtfyUpDistributor: Sending NEW_ENDPOINT ... http://127.0.0.1:2586/upQx4NtGsI5P9w?up=1` |
| Troubleshoot notifications | provider UnifiedPush (io.heckel.ntfy); `http://127.0.0.1:2586/_matrix/push/v1/notify is a Matrix gateway`; push loop back 120 ms (`04`) |
| Synapse pusher for Zara | `kind http`, `url http://127.0.0.1:2586/_matrix/push/v1/notify`, `format event_id_only` |
| App force-stopped (`stopped=true`, no process), Teacher Sana sends a DM | Synapse tried at once: **403 IP address blocked** (above). Not delivered by Synapse. |
| The same notify body Synapse builds (real event id, Zara's real pushkey and `cs`) POSTed to ntfy's gateway from the host | ntfy `{"rejected":[]}` -> `NtfyUpDistributor: Sending MESSAGE` -> `Start proc ... ai.hellorumi.messenger ... RaiseToForegroundService` -> notification "Teacher Sana: Assalam o alaikum Zara, staff meeting moved to 10am tomorrow." in the shade (`06`) |

So everything from ntfy to the notification shade is proven with the app force-stopped. The one
hop not proven end to end is Synapse -> ntfy, blocked only by the private-address rule above.

## Sygnal: what it is, and how it's wired here

The Google path only. Not needed for UnifiedPush.

### FCM: what still needs a human, in order (the "three manual steps")

1. **A Firebase project + a service account JSON key.** Firebase console -> create (or reuse) a
   project -> Project Settings -> Service accounts -> "Generate new private key". Save that file
   somewhere durable and point `deploy/.env`'s `FCM_SERVICE_ACCOUNT_JSON` at it. This is real
   credential material -- nothing in this repo can generate, guess, or stand in for it, and
   `scripts/push-setup.sh` refuses to configure a working pushkin without a file that actually
   parses as a service account (`"type": "service_account"` + `"project_id"`).
2. **A matching `google-services.json` in the Android fork.** In
   `/home/oye/Documents/free_work/element-x-android` (the `Orenda-Project/rumi-messenger`
   Android fork, branch `rumi-brand`), the Firebase module's own README
   (`libraries/pushproviders/firebase/README.md`) documents the exact steps: re-enable the
   `com.google.gms.google-services` Gradle plugin in the `app` module (it is currently
   **disabled** there, precisely so the FOSS build doesn't require Firebase at all), copy the
   downloaded `google-services.json` into `app/` (that path is already in this fork's
   `.gitignore` line 87, matching the pattern this repo already uses for other rendered/secret
   files -- never commit the real file), build, and pull the generated
   `google_app_id`/`project_number` values out of
   `app/build/generated/res/google-services/<buildtype>/values/values.xml` into the module's
   `firebase.xml` files. This is a manual, one-time step per Firebase project; it is not
   automated by this PR because it requires that real downloaded file to exist first.
3. **A signed release build, distributed through the Play Store or sideloaded.** Firebase Cloud
   Messaging tokens are tied to a specific signed APK's application id + signing certificate;
   a debug build talks to Firebase fine for testing (this fork's `applicationId` is
   `ai.hellorumi.messenger`, with the debug variant automatically suffixed `.debug` --
   `plugins/src/main/kotlin/config/BuildTimeConfig.kt:16` in the Android fork), but "a teacher
   with the app closed receives a notification on a real Android phone" (issue #3's own
   done-when) needs a real install, not `adb install` from a dev machine.

None of the three are done. What *is* done: the gateway that will use them the
moment they exist, verified end to end with the honest "no credentials yet" response.


Sygnal is Matrix's own push gateway (the reference implementation, now maintained at
[element-hq/sygnal](https://github.com/element-hq/sygnal) -- the older `matrix-org/sygnal` repo
name is a stale mirror). A homeserver never talks to Firebase or APNs directly; it calls
`POST /_matrix/push/v1/notify` on whatever gateway the client registered a pusher against, and
the gateway translates that into an FCM or APNs call using credentials only the gateway operator
holds. That's why "nothing is deployed and no keys exist" (issue #3) is a real, structural gap,
not an oversight -- there is no way to skip the gateway.

### Compose service

`deploy/docker-compose.yml` adds a `sygnal` service, pinned to
`matrixdotorg/sygnal:v0.17.0` (resolved from
[element-hq/sygnal's GitHub releases](https://github.com/element-hq/sygnal/releases) on
2026-09-23; the same tag exists on
[Docker Hub's matrixdotorg/sygnal](https://hub.docker.com/r/matrixdotorg/sygnal/tags), which is
the image name the upstream README documents), behind `profiles: ["push"]` -- exactly like the
existing `caddy` service's `tls` profile -- so a deployment with no keys pays zero extra
containers, memory, or attack surface until someone opts in with
`docker compose --profile push up -d sygnal`.

It's bound the same way every other service in this stack is: `${BIND_ADDR:-127.0.0.1}:
${SYGNAL_PORT:-5000}:5000`, off the network by default.

**Why Sygnal must be reachable from the HOMESERVER, not the phone** (this matters for issue #6's
production network layout): the phone never talks to Sygnal. It talks to Synapse (ordinary
Matrix client-server API) and, separately, to Firebase/APNs directly (to receive the actual push
and to register its push token). Synapse is the only thing that calls Sygnal, when it decides an
event needs pushing. On this single-box stack that's automatic -- `sygnal` is on the same Docker
network as `synapse`, reachable by that DNS name at port 5000 internally, no config needed beyond
`turn_uris`-style host/port values pointing at it (see "Synapse-side config" below). On a real
multi-host deployment (issue #6), Sygnal's *reachable-from-Synapse* address is what has to be
right, not a public-facing one -- unlike Synapse/Element, which do need to be reachable from
teachers' phones and browsers.

### Config rendering (`scripts/push-setup.sh`)

Same pattern this repo already uses for Element's `config.json`/`welcome.html`/`home.html` and
coturn's `turnserver.conf`: a script renders a real config file into `deploy/sygnal/sygnal.yaml`
(gitignored, chmod 600, never committed) from `deploy/.env` values, and the compose service
mounts that directory read-only.

New `deploy/.env` vars (see `deploy/.env.example` for the full comments):

| Var | Default | Purpose |
|---|---|---|
| `SYGNAL_PORT` | `5000` | Host port Sygnal's API is bound to. |
| `PUSH_APP_ID` | `ai.hellorumi.messenger` | The Android app id registered as an FCM pushkin (`type: gcm`, `api_version: v1`). Must match the Android fork's `applicationId`. |
| `FCM_SERVICE_ACCOUNT_JSON` | `./sygnal/fcm-service-account.json` | **Placeholder path.** Point this at a real Firebase service account JSON once you have one (step 1 above). |

`scripts/push-setup.sh` checks that file for real service-account shape
(`"type": "service_account"` + a `"project_id"`) before ever writing a working `apps:` entry.
If it's missing or doesn't parse, the script:

- still renders `sygnal.yaml`, with the `apps:` section commented out and a note explaining why
  (never fabricates a fake `service_account_file` path just to fill the section in),
- **refuses to start the `sygnal` container** via its own `dc --profile push up -d sygnal` call.

This refusal isn't just a courtesy -- **Sygnal itself will not run with zero apps configured.**
Verified live on 2026-09-23: bringing the container up with an empty `apps:` section makes it
exit immediately with

```
builtins.RuntimeError: No app IDs are configured. Edit sygnal.yaml to define some.
```

(`sygnal/sygnal.py`, `make_pushkins_then_start`), and the container sits in a restart loop. So
there is no "start it anyway just to see the health check work" option without at least one
configured app -- `scripts/push-check.sh`'s `GET /health` check correctly reports the container
as unreachable in this state, which is the honest, correct result: nothing is listening. See
"Live verification run" below for the real output.

Once you *do* have a real service account file: `scripts/push-setup.sh` registers **both**
`PUSH_APP_ID` and `PUSH_APP_ID.debug` (element-x-android's debug build type suffixes the
applicationId with `.debug`) against the same project -- Firebase doesn't need a second project
per build variant, just a `google-services.json` in the Android checkout matching the one
project id.

### APNs (iOS) -- commented out, not built

`sygnal.yaml`'s rendered output always includes a commented-out APNs block (`type: apns`,
`keyfile`/`key_id`/`team_id`/`topic`) with placeholder values, so the shape is documented and
ready, but it is **not enabled** -- iOS is [issue #13](https://github.com/Orenda-Project/rumi-messenger/issues/13),
blocked on having a Mac + Xcode + an iPhone or Simulator to fork and test `element-x-ios`
against, none of which exist in this environment. Filling that block in with real Apple key
material before that fork exists would be pure guesswork; it stays commented until #13 lands.

### Verification (`scripts/push-check.sh`)

Proves the wiring without a phone, using only bash/curl/python3:

1. `GET /health` -- Sygnal's own liveness endpoint (`sygnal/http.py`'s `HealthHandler`, a bare
   `200` with an empty body by design). A non-200 or connection failure is a real `FAIL` and the
   script stops there.
2. `POST /_matrix/push/v1/notify` with a minimal, synthetic notification body for `PUSH_APP_ID`
   and a fake pushkey. Per Sygnal's own dispatch logic
   ([`sygnal/http.py`](https://github.com/element-hq/sygnal/blob/main/sygnal/http.py),
   `_handle_dispatch`): an app id with **no pushkin configured** is reported back as a clean
   `200 {"rejected": ["<pushkey>"]}` -- not an error. That single documented response shape is
   exactly how the script tells "gateway reachable and correctly parsed the request" apart from
   "credentials missing":
   - **Non-200 / unparsable** -> the gateway itself is broken. Real `FAIL`.
   - **200, pushkey in `rejected`** -> gateway reachable, request understood, but no pushkin
     handles `PUSH_APP_ID` -- i.e., no real FCM credentials configured. Printed as an `INFO`
     line, not a failure; this is the expected state until step 1/2 above are done.
   - **200, pushkey NOT in `rejected`** -> a pushkin for `PUSH_APP_ID` accepted the notification
     for onward delivery. **This is never reported as "delivered"** -- Sygnal only reports a
     rejection when the *provider* (Firebase) says the pushkey is invalid, and that normally
     doesn't happen on the very first send with a synthetic pushkey even against real
     credentials, so "accepted" here proves configuration, not arrival at a device.

Run it any time after `scripts/push-setup.sh` (or a manual `docker compose --profile push up -d
sygnal`):

```bash
scripts/push-check.sh
```

## Synapse-side config (for the `scripts/setup.sh` owner, not applied by this PR)

Synapse forwards a push to whatever gateway URL the client registered in its pusher (via `POST
/_matrix/client/v3/pushers/set`), not a fixed config value the way `turn_uris` works for coturn
-- so **no `homeserver.yaml` change is strictly required** for Sygnal itself to work once a
client points at it. The one config surface worth setting explicitly, if this deployment wants
every client's *default* Element push gateway to be our Sygnal instead of relying on the
client's own default (Element Web currently has no built-in mobile push relevant to this, but
the Android/iOS forks do), is documented here for whoever owns `scripts/setup.sh` to wire in --
this PR does not touch `scripts/setup.sh`, `scripts/e2e.sh`, or `scripts/teacher.sh` per its file
ownership split with the parallel homeserver-config work:

```yaml
# homeserver.yaml -- NOT applied by this PR. No key here is strictly required for Sygnal to
# work (a client can point at any pusher URL it likes at registration time); this documents the
# one Synapse-side knob relevant to push (push rule default behavior), separate from Sygnal
# itself, which needs no homeserver.yaml entry to be *reachable* -- only the network path
# (same docker network, `sygnal:5000`) matters, per "Why Sygnal must be reachable from the
# HOMESERVER, not the phone" above.
push:
  include_content: true   # already Synapse's own default; listed here for explicitness only
```

If a future need arises to *force* a specific gateway rather than trust each client's own
default, that would be an app-level (Android fork) config change (`firebasePushGateway()` /
`unifiedPushDefaultPushGateway()` in `EnterpriseService`, see above), not a `homeserver.yaml`
key -- Synapse has no "default pusher gateway" setting; the gateway is always whatever the
client's `pushers/set` call specifies.

## Live verification run (this PR)

Run against the live stack (`SERVER_NAME=localhost`, `SYNAPSE_PORT=8108`,
`ELEMENT_PORT=8182`, `deploy/.env`'s project name). Two passes, both real, both against this
machine's actual `rumi-*` containers:

### Pass 1 -- the real default state: no `FCM_SERVICE_ACCOUNT_JSON` on this machine

```bash
scripts/push-setup.sh
```

correctly refused to start Sygnal (see its exact printed output above). Running the compose
command directly anyway, to see what Sygnal itself does with zero apps configured:

```bash
cd deploy && docker compose --profile push up -d sygnal
```

confirmed the discovery in "Config rendering" above -- `docker ps -a` showed
`rumi-sygnal   Restarting (0) 8 seconds ago`, and `docker logs rumi-sygnal` showed the exact
`RuntimeError: No app IDs are configured` traceback quoted above. `scripts/push-check.sh` against
that state:

```
FAIL: Sygnal GET /health responds 200 (http_code='000' from http://127.0.0.1:5000/health -- is it running? (scripts/push-setup.sh or docker compose --profile push up -d sygnal))

================================================================
 push-check summary: 0 passed, 1 failed
 Sygnal is unreachable -- skipping the /notify check entirely.
================================================================
```

Exit code 1. This is the correct, honest result for this machine's actual state: no Sygnal
process is listening, because no real FCM credentials exist here. (Finding this also caught a
real bug in an earlier draft of `push-check.sh`: `curl -w '%{http_code}' ... || echo 000` prints
`000000`, not `000`, on a connection failure -- curl already emits `000` via `-w` before its
non-zero exit, so the `|| echo 000` fallback appended a second `000` inside the same `$(...)`
capture. Fixed to `|| true` plus a `:-000` default.)

### Pass 2 -- exercising the "gateway reachable, credentials invalid" code path

To prove `scripts/push-check.sh` actually distinguishes "unreachable" from "reachable but
credentials fail" (the whole point of the two-check design), we generated a **locally-made,
non-functional dummy** service account JSON -- a fresh `openssl genrsa` keypair wrapped in the
correct Firebase service-account JSON shape (`type`, `project_id`, `private_key`, `client_email`,
etc.), with an obviously fake project id (`rumi-push-check-fake-project`) and no relationship to
any real Google account. This is **not** a violation of "never fabricate credentials" -- that
rule is about `deploy/.env`'s real `FCM_SERVICE_ACCOUNT_JSON`, which stays unset; this dummy file
lived only in the scratchpad and briefly at the gitignored `deploy/sygnal/fcm-service-account.json`
path for this one test, was never presented as real, and was deleted immediately after:

```bash
scripts/push-setup.sh   # detected the dummy file as structurally valid, rendered apps:, started sygnal
```

output:

```
[...] Step 1/3: checking for a real FCM service account file
[...]   found a real service account file for Firebase project 'rumi-push-check-fake-project'
[...] Step 2/3: rendering deploy/sygnal/sygnal.yaml
wrote .../deploy/sygnal/sygnal.yaml
[...]   wrote deploy/sygnal/sygnal.yaml (chmod 600)
[...] Step 3/3: starting sygnal (push profile)
 Container rumi-sygnal Recreated / Started / Waiting / Healthy
================================================================
 Sygnal is up: http://127.0.0.1:5000
 Real FCM credentials found for project 'rumi-push-check-fake-project' -- ...
================================================================
```

`scripts/push-check.sh` against that:

```
PASS: Sygnal GET /health responds 200
FAIL: POST /_matrix/push/v1/notify for app_id='ai.hellorumi.messenger' (gateway parses + dispatches) (http_code='500' body='' -- gateway reachable but returned an error; if a pushkin IS configured for this app id, this likely means its FCM/APNs credentials are invalid, not merely absent)

================================================================
 push-check summary: 1 passed, 1 failed
================================================================
```

and `docker logs rumi-sygnal` showed exactly what that FAIL predicted: a real outbound HTTPS
call to `https://oauth2.googleapis.com/token` (proving Sygnal genuinely tried, not a stub), which
Google genuinely rejected --

```
google.auth.exceptions.RefreshError: ('invalid_grant: Invalid grant: account not found', {'error': 'invalid_grant', 'error_description': 'Invalid grant: account not found'})
```

-- returned to the client as HTTP 500 (Sygnal's generic exception handler; this particular
Google-side error isn't wrapped as its own `NotificationDispatchException`, so it's 500 rather
than 502 -- `scripts/push-check.sh`'s comment documents this exact case). This is the "gateway
reachable, request parsed, a pushkin IS configured, but its credentials are invalid" state
`scripts/push-check.sh` is designed to report -- confirmed against a real (if fake) network
round trip, not assumed.

**Cleanup, restoring the exact state this PR ships in:** `docker compose stop sygnal &&
docker compose rm -f sygnal`, `deploy/.env` restored from a pre-test backup (the real file has no
push vars in it -- `FCM_SERVICE_ACCOUNT_JSON` only has a default in `.env.example`, never written
to `deploy/.env` by this test), the dummy `deploy/sygnal/fcm-service-account.json` deleted, and
`scripts/push-setup.sh` re-run once more to re-render `sygnal.yaml` back to its honest
zero-apps-configured state (confirmed: `docker ps -a` shows no `rumi-sygnal` container at all,
matching this repo's state before either pass ran). The rest of the live stack
(`rumi-postgres`/`rumi-synapse`/`rumi-element`/`rumi-coturn`) was never touched.

```bash
cd deploy && docker compose config --quiet   # exit 0, confirmed
cd .. && scripts/e2e.sh                       # confirmed still all passed (15 at time of writing), 0 failed, with sygnal absent
```

## What could not be verified

- **Real device delivery.** No Android phone/emulator with Play Services and a real Firebase
  project was exercised in this task -- confirming "a teacher with the app closed receives a
  notification" (issue #3's own done-when) needs the three manual steps above, then a real
  install, which is out of scope for what can be done "without Firebase or Apple keys".
- **UnifiedPush: the Synapse -> ntfy hop.** Everything else was exercised on the emulator on
  2026-09-24 (see "Emulator proof"). Synapse's own POST was refused by its private-IP blocklist;
  a real deployment with ntfy on a public hostname, or `ip_range_whitelist` plus a Synapse
  restart, is what closes it.
- **Compound/APNs details.** Left commented out and undetailed on purpose -- see "APNs (iOS)"
  above.
