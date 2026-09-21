# Architecture

## Components

```
 Teacher (Element Web / Element X / FluffyChat)
        |  Matrix client-server API, E2EE (Olm/Megolm)
        v
 Synapse homeserver  --  Postgres            (deploy/docker-compose.yml)
        ^
        |  Matrix client-server API, bot account @rumi:<server>
        v
 rumi-platform  --  CHANNEL matrix (additive, like slack/discord)
   inbound/matrix-events.adapter.js  -> Meta-webhook-shaped payload -> existing handlers
   matrix-channel.service.js         <- same method surface as meta-channel.service.js
   matrix-connection.js              -> one shared matrix-bot-sdk client (+ rust crypto for E2EE)
```

Four moving pieces:

- **Postgres** -- Synapse's database. Nothing else talks to it.
- **Synapse** -- the Matrix homeserver. Stores rooms, membership, and events (ciphertext for
  encrypted rooms, plaintext for unencrypted ones). Never sees message plaintext for an
  encrypted room -- encryption and decryption both happen on the clients.
- **Element Web** -- the reference web client, branded for Rumi (see `deploy/element/`).
  Teachers on a phone use Element X or FluffyChat instead (see [MOBILE.md](MOBILE.md)); both
  point at the same Synapse.
- **rumi-platform**, running the Matrix channel driver -- one more messaging channel alongside
  WhatsApp, Slack, and Discord, logged in as `@rumi:<server>`. See
  [RUMI-INTEGRATION.md](RUMI-INTEGRATION.md) for how you connect it.

## Data flow: teacher sends Rumi a message

1. A teacher opens (or is already in) a DM with `@rumi:<server>` in Element and sends a text.
2. Element calls Synapse's client-server API (`PUT
   /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}`). If the room is encrypted,
   Element encrypts the event with the room's Megolm session before sending -- Synapse stores
   ciphertext.
3. Synapse fans the event out over `/sync` to every other member of the room, including the
   `@rumi` bot account.
4. rumi-platform's Matrix connection (`bot/shared/services/messaging/matrix-connection.js`) holds
   one long-lived `matrix-bot-sdk` client doing that `/sync`. If E2EE is active, `matrix-bot-sdk`
   decrypts the event locally (Olm/Megolm session state lives in
   `MATRIX_STORAGE_DIR/crypto`, never on the server) and re-emits a plaintext `room.message`
   event -- so the adapter below never has a separate encrypted-vs-plaintext code path.
5. `inbound/matrix-events.adapter.js` maps that `room.message` event into the same
   Meta-webhook-shaped payload every other channel produces (`{from, id, timestamp, type,
   text: {body}}`, prefixed as `matrix:@teacher:<server>`) and calls the bot's existing
   `handleWebhookPost(req, res)` dispatch -- the ~1000 lines of routing, feature handlers, and
   LLM calls that already exist for WhatsApp/Slack/Discord run completely unchanged.
6. The bot looks the teacher up (or creates them) by that prefixed identity, runs the normal
   feature routing, and calls the LLM via `bot/shared/services/llm-client.js`.

**What the server stores:** for an encrypted room, Synapse stores only ciphertext event
content plus metadata it needs to route the event (room id, sender, timestamp, event id). It
never has the Megolm room key. For an unencrypted room (a fresh install with E2EE off, or a
client that never enabled it) Synapse stores the plaintext body like any other homeserver.

## Data flow: Rumi replies

1. The feature handler calls the messaging router (`bot/shared/services/messaging/index.js`),
   which resolves the `matrix:` prefix to `matrix-channel.service.js` (see
   `channel-registry.js#driverForIdentifier` -- it splits on the *first* colon only, so a Matrix
   user id's own embedded colon, `@teacher:example.org`, is never misread as a channel prefix).
2. `matrix-channel.service.js` resolves (or creates) the DM room for that user via
   `matrix-bot-sdk`'s own `client.dms` manager, backed by `m.direct` account data on the
   homeserver -- durable across restarts, not just this process's memory.
3. It builds the message content (`buildTextContent` -- plain `m.text`, or `m.text` +
   `formatted_body` HTML when the reply looks like markdown) and calls
   `client.sendMessage(roomId, content)`.
4. If the room is encrypted, `matrix-bot-sdk` encrypts the event with the room's Megolm session
   before it leaves the process -- Synapse relays ciphertext it cannot read, same as any other
   member's message.
5. Synapse fans it out over `/sync` to the teacher's client, which decrypts and renders it.
6. One structured log line is written (`logOutbound`) with `channel/direction/roomId/eventId/type`
   -- never the message body. See [LOGGING.md](LOGGING.md).

## The additive-channel pattern, and why the driver lives in rumi-platform

rumi-platform already has this shape for Slack and Discord: a `*-connection.js` (owns the one
shared client), a `*-channel.service.js` (outbound, statically checked against
`meta-channel.service.js`'s method list so a new method never ships silently unimplemented on a
driver), and an `inbound/*-events.adapter.js` (translates that channel's native event shape into
the same Meta-webhook-shaped payload the ~1000-line dispatch logic already understands). Matrix
follows the identical three-file shape.

The alternative -- a standalone bridge process translating Matrix into Meta's webhook format and
POSTing it at rumi-platform's existing `/webhook` endpoint -- was rejected (see
`docs/DECISIONS.tsv`). It would have meant maintaining a second copy of identity handling, media
resolution, and interactive-menu degradation outside the codebase that already does all three for
three other channels, instead of reusing them. The driver being *inside* rumi-platform is what
lets `channel-registry.js`'s existing dispatch, and the ~500 call sites that already route through
it, work for Matrix with zero changes.

## Identity format

Every Matrix-originated user is identified inside rumi-platform as `matrix:@user:server` -- the
literal channel prefix, a colon, then the full Matrix user id (which itself contains a colon
before the homeserver name). `channel-registry.js#driverForIdentifier` splits only on the *first*
colon, so `matrix:@teacher:example.org` always resolves to the `matrix` driver with
`@teacher:example.org` as the remaining id -- never ambiguous, even though Matrix user ids
contain their own colon. Media ids follow the same convention: `matrix:mxc://example.org/abc123`,
so an inbound Matrix attachment id can never be mistaken for a WhatsApp media id.

## The welcome-DM mechanism

Rumi's placement as "one tap away" for every new account is **server-side**, not a client
feature. It used to be simpler: Element Web's `welcome_user_id` config key auto-opens a DM with a
given user for every new account. It's still set in `deploy/element/config.template.json` (it's
documented, harmless, and forward-compatible), but a live test against this stack's Element build
confirmed it does nothing -- `element-web` removed the feature in
[PR #12153](https://github.com/element-hq/element-web/pull/12153); the config key is marked
deprecated in `config.md`, not actually functional (see `docs/DECISIONS.tsv`, 2026-09-21).

The real mechanism has two parts:

1. **Every new account auto-joins `#rumi-announcements:<server>`** via Synapse's own
   `auto_join_rooms` + `autocreate_auto_join_rooms` config (set by `scripts/setup.sh`, step 3).
2. **`inbound/matrix-events.adapter.js` watches that room for joins.** On seeing a new member
   join `#rumi-announcements` (via the `room.event` sync event, since `room.join` only fires for
   the bot's own membership), it opens a real 1:1 DM with that user through the *same*
   `matrix-channel.service.js#sendMessage` path an ordinary reply uses, and sends one warm
   greeting. A `storageProvider`-backed flag (`rumi:matrix:welcomed:<userId>`) makes this
   exactly-once and durable across restarts.

Element carries two branded pages as a client-side complement to the server-side DM, both
rendered from `*.template.html` by `scripts/setup.sh` step 8 and wired into Element's config via
`embedded_pages` in `config.template.json`:

- **`welcome.html`** (`embedded_pages.welcome_url`) -- the **logged-out** page, shown before sign
  in. Its primary action is **"Create an account"** (secondary: "Sign in") -- getting a new
  teacher registered is the priority here, not talking to Rumi yet.
- **`home.html`** (`embedded_pages.home_url`) -- the **logged-in** page, shown once a user is
  signed in but has no rooms open (exactly the state a brand-new account is in, right after
  registering and before the server-side welcome DM has necessarily arrived). Its primary action
  is **"Talk to Rumi"** (secondary: "Start a chat with a colleague").

Together with the server-side welcome DM above, a new account meets Rumi through two independent
paths that don't depend on each other's timing -- see `docs/DECISIONS.tsv` for why both exist.

Element's theming (navy/coral, Inter typeface, the custom "Rumi"/"Rumi Dark" themes) is set in
`config.template.json`'s `setting_defaults.custom_themes`, including a `compound` block of
Element's Compound design-system tokens (`--cpd-color-*`) that theme the newer
Compound-based UI surfaces (buttons, action colors) that the older `colors` keys alone don't
reach.

## Scaling notes

The default stack is **Synapse + Postgres on a single box** -- fine for a school, a small
district, or a pilot. Two directions to grow:

- **Synapse workers.** Synapse supports splitting federation senders, event persisters, and
  sync/typing/presence handling into separate worker processes behind a single Postgres, all
  documented at [element-hq/synapse's worker
  docs](https://element-hq.github.io/synapse/latest/workers.html). This stack doesn't need it
  until you're well past a few thousand concurrent users on one homeserver -- add workers, don't
  rearchitect.
- **Tuwunel as the light swap.** [Tuwunel](https://github.com/matrix-construct/tuwunel) (a
  from-scratch Rust homeserver, single binary, no separate database) is the documented lighter
  alternative for a small, single-node deployment that doesn't need Synapse's admin API surface
  or worker model. It was not chosen for v1 because its appservice/bot APIs and docs are less
  mature than Synapse's (`docs/DECISIONS.tsv`), which matters for a bot-account-driven
  integration like this one. If your deployment is small, stays single-node, and you hit friction
  with Synapse's resource footprint, Tuwunel is the swap to evaluate -- it speaks the same
  client-server API, so Element and rumi-platform's Matrix driver don't change.

## Appendix: what Signal-Server would have needed

Signal was the first option considered and rejected (`docs/DECISIONS.tsv`). The reasons are
structural, not a preference:

- **Contact discovery runs in an SGX enclave.** Signal-Server's real contact-discovery service
  depends on Intel SGX remote attestation against Signal's own servers -- there is no documented,
  supported way to run this yourself.
- **`storage-service`, `SVR2`, and `zkgroup` parameters are undocumented or Signal-operated.**
  Group metadata privacy (zkgroup), secure value recovery (SVR2), and encrypted storage sync
  (storage-service) all assume infrastructure Signal runs and doesn't publish the operational
  details for.
- **Net effect:** you can build and run Signal-Server's open-source components, but you get a
  server that cannot do contact discovery, multi-device linking, or several other core client
  features the real Signal app expects -- not a drop-in self-hosted Signal. (See
  softwaremill.com's April 2025 writeup and the jtof-dev/Signal-Docker project's own documented
  gaps, cited in `docs/DECISIONS.tsv`.)

Matrix gives the same *shape* Signal offers -- a store-and-forward server that never sees
plaintext in encrypted rooms, keys held only on clients, multi-device support -- but every piece
of it (the homeserver, the client-server spec, Olm/Megolm) is documented and runnable end to end
on hardware you control, which is what made it the only real self-hosted option for this
project.
