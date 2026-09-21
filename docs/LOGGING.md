# Logging

Two systems produce logs here: the Synapse/Element deploy stack, and rumi-platform's Matrix
channel driver. Neither one logs message bodies or tokens.

## Log surfaces

| Surface | Where | Format |
|---|---|---|
| Synapse | `docker logs rumi-synapse` (via `scripts/logs.sh -s synapse`) | JSON lines, one object per line |
| Postgres | `docker logs rumi-postgres` | Postgres's own plain-text log format |
| Element Web | `docker logs rumi-element` | nginx access-log lines (no app-level logging -- it's a static SPA) |
| rumi-platform (Matrix channel) | `bot/logs/bot-<date>.log` on the rumi-platform host, plus stdout (structured JSON via its own `structured-logger`) | one `logToFile(message, data)` call per event, JSON fields on stdout |

`docker logs` **is** the log for every container in this stack -- there is no separate log file
inside `deploy/`. That's why `scripts/logs.sh` is just a thin wrapper over `docker compose logs`.

### A healthy Synapse line

```json
{"timestamp": "2026-09-21T10:14:50+0000", "level": "INFO", "logger": "synapse.storage.databases.main.event_push_actions", "message": "Rotating notifications up to: 86"}
```

Captured live from `rumi-synapse`. Fields: `timestamp` (Synapse's own format, not ISO-8601 --
note the `+0000` with no colon), `level`, `logger` (the Python logger name -- tells you which
Synapse subsystem), `message`. An exception adds `exc_info` with the formatted traceback (see
`deploy/synapse/data/rumi_log_format.py`, written by `scripts/setup.sh` step 4 -- the Synapse
image ships neither `python-json-logger` nor `synapse.logging.formatter.JsonFormatter`, so this
stack drops in a small stdlib-only formatter instead).

### A healthy rumi-platform outbound line

Every outbound Matrix send logs exactly one line, no message body (`matrix-channel.service.js`'s
`logOutbound`):

```
✅ Matrix message sent { channel: 'matrix', direction: 'outbound', roomId: '!abc123:example.org', eventId: '$xyz:example.org', type: 'text' }
```

Fields: `channel` (always `'matrix'` for this driver), `direction` (`'outbound'` or `'inbound'`),
`roomId`, `userId` (present on identity-resolution and welcome-DM lines; not every send logs it
separately since `roomId` already identifies the conversation), `eventId` (the Matrix event id --
your correlation key, see below), `type` (`text` / `reaction` / `m.image` / `m.audio` / `m.video`
/ `m.file` / `sticker`).

### The `welcome_dm` event

When a new account joins `#rumi-announcements` and gets greeted for the first time
(`inbound/matrix-events.adapter.js#sendWelcomeDm`):

```
Matrix: sent new-account welcome DM { channel: 'matrix', event: 'welcome_dm', userId: '@newteacher:example.org', roomId: '!dmroom:example.org' }
```

This fires exactly once per user (tracked via `rumi:matrix:welcomed:<userId>` in the bot's
storage provider, not memory, so a restart doesn't re-greet everyone).

### Failure lines

Decryption failures log without any message content -- there's nothing more to say than "this
event couldn't be read":

```
⚠️ Matrix inbound: failed to decrypt an event -- skipping { channel: 'matrix', direction: 'inbound', roomId: '...', eventId: '...', error: '...' }
```

Send failures log the error message and, where matrix-bot-sdk provides one, the response body
(`matrixErrorDetail`) -- never the outgoing text.

## What is deliberately NOT logged

- **Message bodies.** Every log call in `matrix-channel.service.js` and
  `matrix-events.adapter.js` that touches a real message logs `roomId`/`eventId`/`type`, never
  `content.body`. This is a deliberate privacy choice (teacher-student conversations), not an
  oversight -- if you're debugging a specific message's content, you must go to the homeserver's
  own event store (readable if the room is unencrypted; ciphertext if it's encrypted, by design)
  or reproduce the send in `bot/scripts/matrix-smoke.js`.
- **Tokens and secrets.** `MATRIX_ACCESS_TOKEN`, the Postgres password, the registration shared
  secret, and the admin password never appear in any log line from either system.
  `scripts/setup.sh` prints the generated admin password to its own terminal output exactly once,
  at the end of a fresh run -- not to any log file.
- **Room membership lists, presence, or typing state** beyond what's needed to route a single
  event.

## Correlating a message across Synapse and rumi-platform

The **Matrix event id** (`$xyz:example.org`, or an opaque `$...` string depending on your
homeserver's room version) is the correlation key across both systems:

1. rumi-platform's inbound adapter logs the event id it received (`event.event_id`, surfaced as
   `id` in the Meta-shaped payload it builds, and directly in any inbound error line).
2. rumi-platform's outbound sends log the event id `client.sendMessage()` returns
   (`logOutbound`'s `eventId`).
3. Synapse's own logs reference event ids in its persistence/federation subsystem loggers (e.g.
   `synapse.handlers.message`), searchable with `docker compose logs synapse | grep '<event id>'`.

There is no separate `correlationId` header shared between Synapse and rumi-platform the way
rumi-platform's own WhatsApp/Slack/Discord webhook path has one (that correlation id is minted
per-inbound-HTTP-request; Matrix's inbound path is a persistent `/sync` listener, not a webhook,
so the event id is what plays that role instead).

## Retention

All four containers use the same Docker `json-file` logging driver, configured in
`deploy/docker-compose.yml`'s `x-logging` anchor:

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"
```

Up to 5 rotated files of 10MB each, per container (50MB max per service) -- old log content is
simply dropped once that cap is hit, not archived anywhere. If you need logs retained longer than
that, ship them out with your own log-forwarding setup (Axiom, Loki, etc.) rather than relying on
Docker's local rotation.

rumi-platform's own `bot/logs/bot-<date>.log` files are plain local files with no rotation
built in on the rumi-platform side of this integration -- that's a rumi-platform-repo concern,
not this repo's.
