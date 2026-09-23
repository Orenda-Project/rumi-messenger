# Group Calls + Screen Sharing (issue #2)

1:1 calls (issue #1) are peer-to-peer through coturn -- see `docs/RUNBOOK.md`'s "Calls" section.
Group calls (3+ participants) and screen sharing are a different mechanism: Element Web's
built-in Element Call widget, backed by a **LiveKit** SFU (Selective Forwarding Unit) that
actually mixes/forwards media, authorized through **lk-jwt-service** per
[MSC4195](https://github.com/matrix-org/matrix-spec-proposals/pull/4195).

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
Element Web / Element X (phone)
   |  1. discover the calls backend -- BOTH paths hand out the same PUBLIC URL (LIVEKIT_SERVICE_URL,
   |     default https://{PUBLIC_DOMAIN}/livekit/jwt):
   |       - Synapse  GET /_matrix/client/unstable/org.matrix.msc4143/rtc/transports  (Element X reads this)
   |       - Caddy    GET /.well-known/matrix/client -> org.matrix.msc4143.rtc_foci  (Element Web reads this)
   |  2. POST https://{PUBLIC_DOMAIN}/livekit/jwt/sfu/get  (OpenID token from Synapse)  -- Caddy, prefix stripped
   v
lk-jwt-service -- verifies the OpenID token via GET https://{PUBLIC_DOMAIN}/_matrix/federation/v1/openid/userinfo
   |              (Synapse's stand-alone `openid` resource; the rest of federation stays unserved, issue #8)
   |  replies {url: wss://{PUBLIC_DOMAIN}/livekit/sfu, jwt}   (LIVEKIT_WS_URL -- also public)
   v
LiveKit SFU <-- signalling: wss://{PUBLIC_DOMAIN}/livekit/sfu (Caddy, real TLS)
            <-- media: UDP LIVEKIT_RTC_UDP_MIN-MAX / TCP LIVEKIT_RTC_TCP_PORT, DIRECT to the server
                (LIVEKIT_MEDIA_BIND_ADDR + LIVEKIT_NODE_IP, see "Production" below)
```

Docker-internal names (`lk-jwt-service:8080`, `livekit:7880`, `synapse:8008`) are used only for
server-to-server hops (Caddy's upstreams, LiveKit's webhook). **A client must never be handed
one**: a phone cannot resolve them. That is exactly what the Android run hit -- the dev stack's
hand-edited Synapse config advertised `http://lk-jwt-service:8080`, and Element X showed
OPEN_ID_ERROR in the call lobby. `scripts/calls-check.sh` now fails on that value (checks 7-9).

Compose services: `livekit` (the SFU) and `lk-jwt-service` (the auth bridge), both behind the
`calls` profile. `scripts/setup.sh` renders `deploy/livekit/livekit.yaml` (gitignored) and patches
Synapse's `homeserver.yaml` with:

| Setting | Why |
|---|---|
| `experimental_features.msc4143_enabled: true` + `matrix_rtc.transports` | Synapse v1.161.0 DOES serve MSC4143 `/rtc/transports` once the flag is on (round 1 said it could not; it had tested without the flag). Element X discovers the SFU here. |
| `default_power_level_content_override` (all presets): `org.matrix.msc3401.call.member: 0` | Joining a call sends a `call.member` STATE event; the default `state_default: 50` makes that 403 for an ordinary teacher. Root cause of round 1's second-participant abort (below). Same value Element Web uses when it creates a room itself. |
| `max_event_delay_duration: 24h` (MSC4140 delayed events) | Element Call schedules a server-side "leave" it keeps refreshing; if a phone dies, Synapse sends it. Without this a dead client stays as a "Waiting for media..." ghost tile for hours. |

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
scripts/setup.sh                                    # renders livekit.yaml, patches homeserver.yaml
docker compose --profile calls --profile prod up -d livekit lk-jwt-service caddy
scripts/calls-check.sh                              # 11 falsifiable checks, see "Verifying"
```

`CADDY_TLS_MODE=internal` in `deploy/.env` gives a local self-signed proof (no public DNS); leave
it blank for a real domain (Let's Encrypt, issue #6). With a self-signed cert lk-jwt-service also
needs `LIVEKIT_INSECURE_SKIP_VERIFY_TLS=YES_I_KNOW_WHAT_I_AM_DOING` (local proofs only).

### Production (reaching phones on other networks)

| `deploy/.env` | Value | Why |
|---|---|---|
| `LIVEKIT_SERVICE_URL`, `LIVEKIT_WS_URL` | leave blank | default to `https://PUBLIC_DOMAIN/livekit/jwt` and `wss://PUBLIC_DOMAIN/livekit/sfu`, both through Caddy |
| `LIVEKIT_MEDIA_BIND_ADDR` | `0.0.0.0` | media ports must be reachable directly, not only on 127.0.0.1 |
| `LIVEKIT_NODE_IP` | the server's public (or LAN) IP | otherwise LiveKit advertises its Docker bridge IP, which only the server itself can reach |
| firewall | open `LIVEKIT_RTC_TCP_PORT`/tcp and `LIVEKIT_RTC_UDP_MIN-MAX`/udp | call media |

**Not proven:** all round-2 participants ran on the server machine itself, so the node IP and
firewall path to a phone on another network is untested. The first real-domain deployment must
run a two-phone call before announcing calls to staff.

### Dev stack (`SERVER_NAME=localhost`)

`setup.sh` still works: it advertises `https://localhost/livekit/jwt` and warns that this is
reachable from this machine only. Calls on the dev stack additionally need `prod` up
(`CADDY_TLS_MODE=internal`) and still hit the "localhost" gotcha below, so use a separate
`SERVER_NAME=rumi.calls.test` stack for a real call test (the round-2 recipe, see "Verifying").
The live dev stack predates this change: its homeserver.yaml was hand-edited to
`http://lk-jwt-service:8080` and has no power-level override or delayed events. Re-run
`scripts/setup.sh` on it (restarts Synapse, Element, coturn) to pick them up.


## Local testing gotcha: SERVER_NAME must NOT be the literal string "localhost"

This is the one real surprise found building this out. lk-jwt-service verifies a client's OpenID
token by resolving the homeserver's federation base URL via HTTPS `.well-known/matrix/server`
delegation -- **from inside its own container.** For a real domain this is a non-issue (the
domain resolves to the same reachable address everywhere). For local testing with
`SERVER_NAME=localhost` it breaks: glibc resolves the literal hostname `localhost` via
`/etc/hosts` *before* any DNS/network alias lookup is even attempted, so inside the
`lk-jwt-service` container "localhost" always means itself, never the `caddy` container --
regardless of any Docker network alias (`docker-compose.yml`'s `caddy` service now sets one for
`PUBLIC_DOMAIN`, which is a real, useful fix for any *other* hostname, but is a verified no-op for
this one specific literal value). Verified live: `docker run --rm --add-host=localhost:<ip> alpine
cat /etc/hosts` shows both entries present, but the original `127.0.0.1` one wins because it's
first in the file.

**Practical effect:** on this repo's existing default dev stack (`SERVER_NAME=localhost`), LiveKit
and lk-jwt-service start and pass their own liveness checks, and `.well-known` correctly
advertises `rtc_foci` once `prod`/`tls` is up -- but the actual OpenID handshake that authorizes a
call will fail, because lk-jwt-service can't reach Caddy at "localhost" from inside its own
container. **To actually prove a call end-to-end locally, use a real-looking hostname instead**
(e.g. `SERVER_NAME=rumi.calls.test`), which:
- resolves to `127.0.0.1` on the test machine via Chromium's `--host-resolver-rules` flag (no
  `/etc/hosts` edit, no root needed) for the browser side, and
- resolves inside the Docker network via the `caddy` service's network alias (now added) for the
  container side.

A real production deployment never hits this at all -- a real domain is not literally the string
"localhost" in the first place. This is a local-testing-only wrinkle, documented honestly rather
than worked around with something fragile.

## Known gaps (stated plainly)

1. **Cross-network media untested.** See "Production" above: `LIVEKIT_NODE_IP` and the firewall
   path are wired up but no participant has joined from a second machine or a phone yet.
2. **Element X (Android) not re-tested after the fix.** The server now advertises the public URL
   (calls-check check 7), but the phone run that saw OPEN_ID_ERROR has not been repeated.
3. **UDP media range is small (100 ports by default).** Enough for a staff meeting on one small
   deployment; raise `LIVEKIT_RTC_UDP_MIN`/`MAX` for more concurrent participants.
4. **Pre-existing rooms** keep `call.member` at 50 until an admin lowers it (above).
5. **Headless screen share uses Chromium's fake capture source**, so the shared "screen" is a
   green test pattern with its own clock, not a real desktop. The SFU logged it as
   `source: SCREEN_SHARE` 1920x1080 and the other two participants rendered it in the spotlight
   (evidence below). A real desktop share is the same LiveKit publish path; a manual check with a
   real screen is still worth doing once.
6. **One transient reconnect** is logged per join (`livekitRoom.connect FAILED ... Client initiated
   disconnect`, then `connected to Livekit Server` within a second): Element Call switches from its
   initial transport to the room's active one. Harmless, not a failure.


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

11 checks, each FAILs rather than skips: livekit + lk-jwt-service running, SFU and `/healthz`
answer, Element `feature_group_calls`, `.well-known` advertises `rtc_foci`, **Synapse
`/rtc/transports` URL is public, `.well-known` URL is public, lk-jwt-service's client wss:// URL
is public** (no `lk-jwt-service`/`livekit`/`synapse`/`caddy`/`element` hostnames), new rooms put
`call.member` at 0, and Synapse advertises delayed events (`org.matrix.msc4140`). Falsified live:
against the dev stack (hand-edited `http://lk-jwt-service:8080`, calls profile down) it reports
1 passed, 10 failed, naming the internal URL.

### Round-2 call proof (2026-09-23)

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
