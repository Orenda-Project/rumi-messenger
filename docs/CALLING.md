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
Element Web (embedded Element Call widget)
   |  1. GET https://{PUBLIC_DOMAIN}/.well-known/matrix/client
   |     -> org.matrix.msc4143.rtc_foci: [{type: livekit, livekit_service_url: https://{PUBLIC_DOMAIN}/livekit/jwt}]
   |  2. POST .../livekit/jwt/sfu/get  (Bearer: OpenID token from Synapse)      -- via Caddy, prefix stripped
   v
lk-jwt-service  -- verifies the OpenID token via GET https://{PUBLIC_DOMAIN}/_matrix/federation/v1/openid/userinfo
   |               (also via Caddy -- see "Known gaps" below for why this needs the federation
   |               RESOURCE mounted even though federation_domain_whitelist stays empty)
   |  mints a signed LiveKit JWT
   v
LiveKit SFU  <---- ws://{PUBLIC_DOMAIN}:{LIVEKIT_PORT} (browser connects directly for the actual
                    call media -- plaintext ws://, not wss://; see "Known gaps")
```

Compose services: `livekit` (the SFU) and `lk-jwt-service` (the auth bridge), both behind the
`calls` profile. Config is rendered by `scripts/setup.sh` into `deploy/livekit/livekit.yaml`
(gitignored, same pattern as coturn's `turnserver.conf`).

## Why our pinned Synapse can't serve MSC4143 itself

Synapse's own native `matrix_rtc.transports` config key (which would let Synapse serve the
`/rtc/transports` discovery endpoint directly, no well-known needed) does **not** work on our
pinned v1.161.0 -- verified live: `GET /_matrix/client/versions` reports
`"org.matrix.msc4143": false`, and no such REST module exists in the image
(`ModuleNotFoundError: No module named 'synapse.rest.client.rtc_transports'`). The config key is
harmlessly patched into `homeserver.yaml` anyway (forward-compatible for whenever a future Synapse
release does support it), but the actual discovery path today is Caddy's `.well-known/matrix/client`
response -- which means **a client can only discover the calls backend when the `prod`/`tls`
profile is also running.** `docker compose --profile calls up -d` alone starts LiveKit and
lk-jwt-service but leaves them undiscoverable.

## Bringing it up

```bash
scripts/setup.sh                                    # renders deploy/livekit/livekit.yaml
docker compose --profile calls --profile prod up -d livekit lk-jwt-service caddy
# CADDY_TLS_MODE=internal in deploy/.env for a local self-signed proof (no public DNS needed);
# leave blank for a real domain (Let's Encrypt, same as issue #6's production hardening).
scripts/calls-check.sh                              # falsifiable health check, see below
```

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

## Known gaps (stated plainly, not silently omitted)

1. **Federation resource must be mounted for `/openid/userinfo`, even with federation off (issue
   #8).** lk-jwt-service's OpenID verification call always goes to
   `GET /_matrix/federation/v1/openid/userinfo`, which Synapse only serves when `federation` is in
   a listener's `resources`. Issue #8 removed that resource entirely. The fix that keeps issue
   #8's actual goal intact: `federation_domain_whitelist: []` (already set) independently blocks
   all real inter-server federation traffic (transactions, backfill, invites) regardless of
   whether the resource is mounted -- verified live, `GET /_matrix/federation/v1/version` and
   `GET .../openid/userinfo` both need to be reachable for calls to work at all, and turning the
   resource back on does not reopen actual federation as long as the whitelist stays empty. **This
   repo's default dev stack currently does NOT have the federation resource re-enabled** (that's a
   coordinated change touching issue #8's own territory, left for explicit follow-up rather than
   changed unilaterally here -- see `docs/DECISIONS.tsv`). Until it is, group calls cannot
   actually authorize on this deployment even with `calls`+`prod` up.
2. **Plaintext `ws://` to the SFU, not `wss://`.** The browser connects directly to LiveKit's own
   port for call media, not through Caddy. This only works at all because browsers exempt
   `localhost`/`127.0.0.1`-resolving origins from the "https page can't open ws://" mixed-content
   rule. A real school domain is not exempt -- production needs Caddy (or another TLS-terminating
   proxy) stream-proxying LiveKit's WebSocket port to `wss://`, which is new work, not yet built.
3. **UDP media port range is small (50100-50200, 100 ports) and bridge-published, not
   host-networked**, matching `element-hq/element-call`'s own dev-compose rather than LiveKit's
   own "use host networking for wide UDP ranges" recommendation (which is coturn's shape in this
   repo, at ~16k ports). 100 ports is enough for a handful of concurrent participants per
   call-leg-pair on a single small school deployment, not "one media server handles a few hundred
   concurrent participants" from issue #2's own capacity ask -- that needs raising
   `LIVEKIT_RTC_UDP_MIN`/`MAX` in `deploy/.env` (each participant's media leg claims roughly one
   port) plus enough host resources, and is untested past 2 real browser participants (see the
   Proven/Not proven table below).
4. **`use_external_ip: false`** in the rendered `livekit.yaml` -- same NAT-traversal gap
   coturn's `TURN_EXTERNAL_IP` already documents for 1:1 calls. A deployment behind NAT needs this
   flipped, tracked alongside issue #6.
5. **No screen-share-specific proof beyond what's in the table below.** Screen sharing in Element
   Call is the same LiveKit publish path as camera video (a second track), so nothing
   screen-share-specific was added to the compose/config -- but only what was actually exercised
   with a real screen-share click is claimed as proven.
6. **A second real-browser participant's LiveKit WebSocket handshake failed in the automated
   headless run.** Reproduced twice: participant A (headless Chromium, fake camera) authorizes,
   loads the Element Call widget, and connects to the LiveKit room successfully (confirmed via
   `[CallViewModel] matrixLivekitMembers$ updated` / a real video tile on screen). Participant B
   (a genuinely SEPARATE Chromium process, not just a second browser context -- the first attempt
   with two contexts in one process looked like fake-media-device contention, so this rules that
   out) gets the same room, a correctly minted widget URL with `intent=join_existing`, loads the
   widget, but then logs `Abort connection attempt due to user initiated disconnect` /
   `ConnectionError: Client initiated disconnect` before the LiveKit WebSocket finishes
   connecting. Not chased further given the local-testing environment differences already at play
   (self-signed cert, `--host-resolver-rules` hostname mapping, two full Chromium processes on one
   test machine); genuinely unresolved, not silently worked around. **A real two-person manual
   test (two actual people, two actual devices/browsers, against a `prod`+`calls` deployment) is
   the next real verification step**, not a re-run of this specific headless script.

## Capacity story (issue #2 asked for this explicitly)

One LiveKit SFU instance, sized like this deployment's, handles on the order of tens to a
few hundred concurrent participants depending on host CPU/network (LiveKit's own documented
guidance) -- **not proven by this work**, only the underlying mechanism (2 real browser
participants) was. Scaling further is horizontal: more LiveKit nodes behind a shared Redis-backed
room directory (LiveKit's own multi-node deployment mode), which this deployment does not run
(single node, no Redis) -- a real "few hundred participants" school-wide capacity claim needs that
work plus a real load test, neither of which happened here. State this honestly to Kamal rather
than repeating the vendor number as if it were locally verified.

## Verifying

```bash
scripts/calls-check.sh
```

Checks (falsifiable -- every one fails cleanly, not silently, with the `calls`/`prod` profiles
down): livekit + lk-jwt-service containers running, LiveKit SFU answers on its port,
lk-jwt-service answers `/healthz` (note: singular `/health` 404s -- not a real route on this
image, verified live), Element `config.json` carries `feature_group_calls`, and
`https://{PUBLIC_DOMAIN}/.well-known/matrix/client` advertises `org.matrix.msc4143.rtc_foci`.

None of these checks place an actual call -- see the Proven/Not-proven table in the issue #2
delivery comment for what a real 2-browser Playwright run did and did not prove.

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
