# Calls: 1:1, group, screen sharing (issues #1 + #2)

**On by default.** `scripts/setup.sh` starts the calls server and tells the apps where it is. There
are two call mechanisms:

- **Element Call** (LiveKit SFU + lk-jwt-service, per
  [MSC4195](https://github.com/matrix-org/matrix-spec-proposals/pull/4195)). The phone app (our
  Element X fork) has **no other way to call**: every call from the phone, 1:1 included, is an
  Element Call. The web app uses it too when a teacher picks "Element Call", and for group calls and
  screen sharing.
- **Legacy 1:1 calls** (peer-to-peer WebRTC through coturn), web app only ("Legacy Call"). See
  `docs/RUNBOOK.md`'s "Calls" section.

`CALLS=off` (in `deploy/.env` or exported) leaves LiveKit out, removes the advertisement from
Synapse and hides Element Call in the web app. The phone app then cannot call at all.

**No internet dependency for the call UI.** Both apps ship Element Call inside themselves: the phone
app loads its embedded copy from `https://appassets.androidplatform.net/element-call/index.html`
(Element X's `element-call-embedded` package, see the fork's `docs/element_call.md`; the base URL
is only overridden in hidden developer options), and Element Web 1.12.29 serves its own copy at
`/widgets/element-call/`. Nothing is loaded from `call.element.io`; no self-hosted element-call
container is needed.

## Why LiveKit + lk-jwt-service, not Jitsi

Element Call is what modern Element Web ships for native group calls; Jitsi is the legacy,
deprecated widget path. Element Call's only supported backend is LiveKit. This is also the
component the WhatsApp-replica blueprint already picked in June (per issue #2's own text), so the
work is reusable either way this project goes.

## Why standalone mode, not the application-service (MSC4512) mode

lk-jwt-service supports two integration modes. The modern one -- registering as a Matrix
application service so Synapse proxies `/rtc/livekit/*` requests to it (MSC4502 + MSC4512) --
needs Synapse's `develop` branch (`element-hq/element-call`'s own `docker-compose-dev.yml` pins
`ghcr.io/element-hq/synapse:develop` specifically for this), not our pinned stable v1.161.0.
Standalone mode is the "deprecated but still supported" MSC4195 flow that works against any
stable homeserver: the client presents an OpenID token straight to lk-jwt-service, which verifies
it itself. That's what this deployment uses. See `docs/DECISIONS.tsv`.

## Architecture

```
Element X (phone) / Element Web's Element Call widget
   |  1. discover: Synapse GET /_matrix/client/unstable/org.matrix.msc4143/rtc/transports
   |     -> livekit_service_url = LIVEKIT_SERVICE_URL (both apps read THIS; setup.sh writes it only
   |        when it started LiveKit)
   |  2. POST <LIVEKIT_SERVICE_URL>/sfu/get with an OpenID token from Synapse
   v
lk-jwt-service (inside calls-proxy's network namespace)
   |  verifies the token: https://<server_name>/.well-known/matrix/server, else
   |  https://<server_name>:8448 -> /_matrix/federation/v1/openid/userinfo (Synapse's stand-alone
   |  `openid` resource; the rest of federation stays unserved, issue #8)
   |  creates the LiveKit room via LIVEKIT_URL, replies {url: LIVEKIT_WS_URL, jwt}
   v
LiveKit SFU <-- signalling: LIVEKIT_WS_URL
            <-- media: UDP LIVEKIT_RTC_UDP_MIN-MAX / TCP LIVEKIT_RTC_TCP_PORT, direct to the server
```

What setup.sh hands clients, derived from `PUBLIC_BASE_URL` every run (a value set in
`deploy/.env` wins):

| Stack | `LIVEKIT_SERVICE_URL` (lk-jwt) | `LIVEKIT_WS_URL` (LiveKit) |
|---|---|---|
| plain http (dev, default `localhost`) | `http://<host>:LIVEKIT_JWT_PORT` (8180) | `ws://<host>:LIVEKIT_PORT` (7880) |
| https (`prod` Caddy, real domain) | `https://PUBLIC_DOMAIN/livekit/jwt` | `wss://PUBLIC_DOMAIN/livekit/sfu` |

`<host>` is the hostname in `PUBLIC_BASE_URL`, the same one the TURN URIs use.

**calls-proxy** (a small Caddy, `deploy/livekit/calls-proxy.Caddyfile`) exists for the default
`SERVER_NAME=localhost` stack. lk-jwt-service does both of its own lookups from inside its
container: the OpenID check (always HTTPS federation discovery for the server name) and room
creation (the same `LIVEKIT_URL` it hands clients). With `localhost` both would hit lk-jwt-service
itself. It therefore runs in calls-proxy's network namespace, where `localhost:8448` is a
self-signed TLS proxy to Synapse's one userinfo endpoint and `localhost:LIVEKIT_PORT` forwards to
the SFU. On the plain-http stack setup.sh sets `LIVEKIT_INSECURE_SKIP_VERIFY_TLS` for that
self-signed hop only (there is no TLS anywhere on that stack). On a real domain these lookups
resolve to the prod Caddy exactly as before. calls-proxy also publishes lk-jwt-service's port.

**Why the QA critic saw OPEN_ID_ERROR (2026-09-24, confirmed live).** Commit 50216bd made setup.sh
always advertise `https://PUBLIC_DOMAIN/livekit/jwt`, but the default stack started neither the
`calls` services nor the `prod` Caddy. Every client was sent to `https://localhost/livekit/jwt`,
where nothing listens: the phone showed a dark call screen then OPEN_ID_ERROR, the web console
logged `Failed to authenticate to transport https://localhost/livekit/jwt`. `calls-check.sh` on
that stack: 4 passed, 8 failed; the new e2e check failed with HTTP 000.

The Caddy `.well-known/matrix/client` no longer carries `org.matrix.msc4143.rtc_foci`: Synapse's
`/rtc/transports` is the single discovery source, so `CALLS=off` can never leave a stale address.

Synapse settings setup.sh writes:

| Setting | Why |
|---|---|
| `experimental_features.msc4143_enabled` + `matrix_rtc.transports` (only when CALLS is on) | Synapse v1.161.0 serves MSC4143 `/rtc/transports` with the flag on. Both apps discover the SFU here. |
| `default_power_level_content_override` (all presets): `org.matrix.msc3401.call.member: 0` | Joining a call sends a `call.member` STATE event; the default `state_default: 50` makes that 403 for an ordinary teacher (round 1's second-participant abort, below). |
| `max_event_delay_duration: 24h` (MSC4140 delayed events) | Element Call schedules a server-side "leave" it keeps refreshing; if a phone dies, Synapse sends it, so no "Waiting for media..." ghost tile. |

## Why the second participant was dropped in round 1 (root cause, reproduced + fixed in round 2)

Not the certificate, not `--host-resolver-rules`, not LiveKit's ICE/port setup. The browser log
of the second participant, in order:

1. `connected to Livekit Server ... participant: @+923001110002...` -- the websocket DID connect.
2. `M_FORBIDDEN: [403] You don't have permission to post that to the room. user_level (0) <
   send_level (50) (.../state/org.matrix.msc3401.call.member/...)`
3. `MembershipManager encountered an unrecoverable error` -> `Connection lost` ->
   `Abort connection attempt due to user initiated disconnect` / `Client initiated disconnect`.

The room was created through the client-server API (round 1 and round 2 both did this; so do the
bot, admin scripts and Element X), which gets Synapse's default power levels: every state event
at 50. The creator is 100, so participant A could always join; every other teacher got 403, and
Element Call itself tore down the LiveKit connection -- the "user initiated disconnect" was the
app, not the user. Proof it is causal: same stack, same browsers, a room created after the
power-level override joins all participants (evidence below); the room created before it still
drops the second participant.

**Rooms created before this change keep `call.member` at 50.** Fix one in Element Web: Room
settings -> Roles & Permissions -> the "Join Element Call calls" permission (label may vary
by Element version) -> Default. Or as the
room's admin via the API: `PUT /_matrix/client/v3/rooms/<room>/state/m.room.power_levels/` with
`events["org.matrix.msc3401.call.member"] = 0` added to the current content.

## Bringing it up

```bash
scripts/setup.sh          # starts livekit + calls-proxy + lk-jwt-service unless CALLS=off
scripts/calls-check.sh    # 12 falsifiable checks, see "Verifying"
```

Ports on the default stack (all on `BIND_ADDR`, 127.0.0.1 by default):

| Port | What | Who connects |
|---|---|---|
| 8180/tcp (`LIVEKIT_JWT_PORT`) | lk-jwt-service (published by calls-proxy) | the apps, for the call token |
| 7880/tcp (`LIVEKIT_PORT`) | LiveKit signalling (ws) | the apps |
| 7881/tcp (`LIVEKIT_RTC_TCP_PORT`) | LiveKit media over TCP | the apps, when UDP is not possible |
| 50100-50200/udp | LiveKit media | the apps |
| 3478/tcp+udp | coturn | web app legacy 1:1 calls |

### Android emulator on the dev stack

The emulator's `localhost` is the emulator itself. Forward the TCP ports to the host:

```bash
adb reverse tcp:8108 tcp:8108   # Synapse (SYNAPSE_PORT)
adb reverse tcp:8180 tcp:8180   # lk-jwt-service
adb reverse tcp:7880 tcp:7880   # LiveKit signalling
adb reverse tcp:7881 tcp:7881   # LiveKit TCP media
adb reverse tcp:3478 tcp:3478   # coturn
```

`adb reverse` cannot forward UDP. LiveKit's UDP candidates carry its Docker bridge IP, which the
emulator's NAT reaches through the host anyway, and the TCP 7881 fallback covers the rest.

### Production (reaching phones on other networks)

| `deploy/.env` | Value | Why |
|---|---|---|
| `PUBLIC_BASE_URL` | `https://...` | makes setup.sh hand out the Caddy URLs (`--profile prod` must be up) |
| `LIVEKIT_SERVICE_URL`, `LIVEKIT_WS_URL` | leave blank | derived, see the table above |
| `LIVEKIT_MEDIA_BIND_ADDR` | `0.0.0.0` | media ports must be reachable directly |
| `LIVEKIT_NODE_IP` | the server's public (or LAN) IP | otherwise LiveKit advertises its Docker bridge IP |
| firewall | open `LIVEKIT_RTC_TCP_PORT`/tcp and `LIVEKIT_RTC_UDP_MIN-MAX`/udp | call media |

A plain-http stack whose `SERVER_NAME` is not `localhost` (for example a LAN IP) is **not
covered**: lk-jwt-service's OpenID check would look for HTTPS on that name. Use the `prod` profile
with a real hostname for anything beyond one machine.

## Known gaps (stated plainly)

1. **Real phones and cross-network media untested.** Proven: Android emulator <-> web app on one
   machine. `LIVEKIT_NODE_IP` and the firewall path to a phone on another network are wired up but
   no call has crossed two networks yet. Run a two-phone call before announcing calls to staff.
2. **Group calls not re-run on the default stack or from the phone.** The 3-person proof below
   was on the separate `rumi.calls.test` HTTPS stack, from the web app.
3. **First video call asks for the camera** (Android permission prompt). Until the teacher taps
   "While using the app", the phone joins without video; if the app is backgrounded at that
   moment the call screen can close while the call keeps running (seen 2026-09-24, see below).
4. **UDP media range is small (100 ports).** Raise `LIVEKIT_RTC_UDP_MIN`/`MAX` for more
   concurrent participants.
5. **Pre-existing rooms** keep `call.member` at 50 until an admin lowers it (above).
6. **Headless screen share** used Chromium's fake capture source, not a real desktop.
7. **Web "Call started" timer after a voice call the web user started (Element Web v1.12.29 bug,
   client-side only).** The server side is clean: Element Call gives up ringing after ~30 s (or
   on End call), sends the empty `org.matrix.msc3401.call.member` leave, its MSC4140 delayed leave
   is already consumed, and LiveKit closes the room (IDLE_TIMEOUT). But in the caller's own tab the
   DM tile stays "ongoing" and counts up forever: the header Voice call button goes through
   RoomViewStore's `voiceOnly` path, which sets `call.presented = true` without opening the call
   view, and when the widget closes itself (`models/Call: The widget died; treating this as a user
   hangup`) nothing sets `presented` back to false, so `ElementCall.checkDestroy()` (which requires
   `!presented`) never removes the Call from CallStore, and the RTC-notification tile renders as
   `ongoing-call-dm`. The callee, other sessions and a reload all show the correct ended
   "Voice call" tile; video calls open the call view and are not affected. No server or config
   setting reaches this. Teacher workaround in TEACHER-GUIDE: reload the page. Evidence and repro:
   DECISIONS.tsv row `web-voice-call-ghost-timer`.

## Capacity story (issue #2 asked for this explicitly)

Proven here: **3 participants** in one call on one LiveKit node, all video tiles playing, plus a
screen share. One LiveKit node of this size handles tens to a few hundred participants
depending on host CPU/bandwidth (LiveKit's own guidance) -- **not load-tested here**. Scaling
further is horizontal: more LiveKit nodes behind a shared Redis (LiveKit multi-node mode), which
this deployment does not run. Do not tell a school "a few hundred" until a real load test.

## Verifying

```bash
scripts/calls-check.sh
# local test domain with no DNS:
CALLS_CHECK_RESOLVE=rumi.calls.test:443:127.0.0.1 scripts/calls-check.sh
```

12 checks, each FAILs rather than skips: livekit, lk-jwt-service and calls-proxy running; SFU and
`/healthz` answer; Element `feature_group_calls`; Synapse `/rtc/transports` URL is not a
Docker-internal name; **that advertised URL answers; a real OpenID token gets a LiveKit JWT from
it**; the ws(s):// URL it hands back is public; new rooms put `call.member` at 0; delayed events
(`org.matrix.msc4140`). `scripts/e2e.sh` repeats the OpenID -> JWT check against the advertised URL
(check "advertised call transport answers...") so a dead address fails the main suite too.
Falsified live: on the pre-fix dev stack calls-check reported 4 passed / 8 failed and e2e 16/1.

### Phone <-> web proof on the default stack (2026-09-24)

Default dev stack (`SERVER_NAME=localhost`, no Caddy) after one `scripts/setup.sh` run. Android
emulator (API 34), release app `ai.hellorumi.messenger` as Teacher Zara, `adb reverse` as above;
web app `http://127.0.0.1:8182` as Teacher Hamza in headless Chromium (fake camera/mic). Evidence in
the personal-agent-v2 vault, `projects/rumi-messenger/evidence-2026-09-24/calls-fix/`.

| Item | Result |
|---|---|
| Phone taps voice call -> web rings | PROVEN: "Incoming voice call, Teacher Zara Khan, Decline / Join" (`w04`) |
| Both sides in the call, timer | PROVEN: web "Call in progress (0:35)" + Zara's tile (`w05`); phone call screen with Hamza, then "Call in progress" row (`p03`, `p05`); LiveKit: both participants active, both published audio |
| Clean hang-up + history | PROVEN: web ends, phone call closes; "Call started 6:52" (phone) / "Voice call" (web) (`p06`, `w07`, `w17`) |
| Video, both directions | PROVEN on the second attempt: phone shows Hamza's camera + own preview (`p15`), web shows Zara's camera (`w15`); LiveKit: CAMERA + MICROPHONE tracks from both |
| Video timer on the phone | PROVEN: "Call in progress (1:14)" (`p10`, during the first, interrupted attempt; in the second the PiP window covers it) |
| First video attempt | Interrupted: another agent switched the shared emulator to a different app while the camera prompt was open; the call kept running without the phone's video and was ended from the web |
| Any OPEN_ID_ERROR / "Failed to authenticate to transport" | none (phone logcat, web console); lk-jwt-service issued 23 LiveKit tokens in the window (calls plus the e2e/calls-check runs) |

### Round-2 group-call proof (2026-09-23, separate HTTPS stack)

Isolated stack (`COMPOSE_PROJECT_NAME=rumicallsverify`, `SERVER_NAME=rumi.calls.test`, own ports,
coturn not started so the dev stack's coturn is untouched), `calls` + `prod` with
`CADDY_TLS_MODE=internal`. Separate headless Chromium processes (`--use-fake-device-for-media-stream
--use-fake-ui-for-media-stream --ignore-certificate-errors --host-resolver-rules="MAP
rumi.calls.test 127.0.0.1" --auto-select-desktop-capture-source="Entire screen"`), one per
throwaway teacher from `scripts/teacher.sh`, all in one room. Evidence in the personal-agent-v2
vault, `projects/rumi-messenger/evidence-2026-09-23/calls-round2/`.

| Item | Result |
|---|---|
| Round-1 abort reproduced in a room with default power levels | second participant 403 on `call.member` -> "Connection lost" |
| 2 participants, both tiles visible in both browsers | PROVEN (each browser: 2 playing 1280x720 videos) |
| 3 participants, all tiles in all three browsers | PROVEN (0 ghost tiles) |
| Screen share seen by the other participants | PROVEN (SFU `source: SCREEN_SHARE`; spotlight tile in both viewers) |
| Dead clients' memberships expire (delayed events) | PROVEN (rerun in the same room after browsers were killed: 0 ghosts) |


## Operational gotcha found while verifying: don't run a second stack's coturn alongside this one

coturn uses `network_mode: host` (see its comment in `docker-compose.yml`), which means TWO
coturn containers from two different `docker compose` projects on the same machine both bind the
SAME host port 3478 -- Docker did not refuse the second one, and BOTH reported healthy, but
credentials generated by one stack's Synapse got rejected by whichever coturn process actually
answered ("credentials ... are wrong (message integrity does not match any auth secret)" in
`docker logs`). This broke this repo's own `scripts/e2e.sh` coturn check while a second
(`rumi.calls.test`) verification stack was running side by side for this work. Fixed by tearing
the second stack down completely (`docker compose down -v` in its own `deploy/`, not just
stopping the profile's containers) -- `scripts/e2e.sh` returned to 15/15 immediately after. If you
ever need a second full stack (e.g. for a future verification run against a different
`SERVER_NAME`), either run it on a different host, or don't bring up its `coturn` service at all
while the primary stack's is up.
