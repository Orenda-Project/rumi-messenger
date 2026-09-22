# Connecting Rumi

Rumi Messenger runs the homeserver and the client. rumi-platform runs Rumi -- the teaching
companion who talks back. This page connects the two.

Matrix is an **additive channel** in rumi-platform, the same way Slack and Discord are: it runs
alongside whatever your primary channel is (WhatsApp via `baileys` or `meta`), not instead of it.
Setting `MATRIX_HOMESERVER_URL` + `MATRIX_ACCESS_TOKEN` is what turns it on -- there's no
`CHANNEL_DRIVER=matrix` switch to flip.

## Teachers register with their phone number

A teacher's username on this server must be their phone number in digits, for example
`923001234567`, with no plus sign, spaces or dashes. The sign-up page says so, and it is not only a
convention that makes the product feel like WhatsApp.

Rumi records who asked for a lesson plan, a quiz or a video in columns that were sized for a phone
number, twenty characters. An additive channel sends a prefixed identity rather than a bare number,
and anything longer than twenty characters is rejected by the database. A teacher sees a polite
"something went wrong" while the real cause is hidden in the log. We hit exactly this, and it is
tracked upstream as [rumi-platform#107](https://github.com/Orenda-Project/rumi-platform/issues/107),
which also shows that Discord has the same fault today.

Using the phone number keeps our identity inside that limit without changing the shared schema, so
this deployment works against rumi-platform as it stands.

What this means in practice:

- Tell staff to register with their number. The sign-up page repeats it.
- Set display names to real names, so colleagues see "Ayesha Khan" and not a number.
- Admin or service accounts may keep ordinary usernames. They still work, and the bot logs a warning
  the first time one is used, because the long flows above can fail for them.
- Two teachers cannot share a number, which is the behaviour you want anyway.

Once rumi-platform#107 is fixed, this becomes a preference rather than a requirement, and the
constraint here can be relaxed.

## Which rumi-platform branch carries this

The Matrix channel driver lives on rumi-platform's `feat/matrix-channel` branch (three files:
`bot/shared/services/messaging/matrix-connection.js`, `matrix-channel.service.js`, and
`inbound/matrix-events.adapter.js`, plus the `MATRIX_*` block in `.env.template`). PR:
`https://github.com/Orenda-Project/rumi-platform/pull/104`. If that PR has merged to `main` by the time you read this, just use `main`
instead -- the steps below are the same either way.

## Steps

### 1. Run setup here

```bash
git clone https://github.com/Orenda-Project/rumi-messenger.git
cd rumi-messenger
scripts/setup.sh
```

This brings up Postgres, Synapse, and Element, creates an admin account and the `@rumi` bot
account, and -- as its second-to-last step -- writes `deploy/rumi-channel.env`:

```env
MATRIX_HOMESERVER_URL=http://localhost:8008
MATRIX_ACCESS_TOKEN=syt_...
MATRIX_USER_ID=@rumi:localhost
```

(Real values from your run -- `PUBLIC_BASE_URL`, a real access token, and `@rumi:<your
SERVER_NAME>`.) This file is `chmod 600` and gitignored; it never leaves your machine on its own.

### 2. Connect it to a rumi-platform checkout

```bash
scripts/connect-rumi.sh /path/to/your/rumi-platform
```

What it does, in order:

1. Confirms `/path/to/your/rumi-platform` looks like a real rumi-platform checkout (it has
   `bot/whatsapp-bot.js` and `.env.template` -- refuses to touch anything else).
2. Reads `deploy/rumi-channel.env` from this repo.
3. If the target has no `.env` yet, creates one from its own `.env.template`. If it already has
   one, backs it up first to `.env.bak.<unix timestamp>` in the same directory.
4. Writes/updates exactly three keys in the target's `.env`: `MATRIX_HOMESERVER_URL`,
   `MATRIX_ACCESS_TOKEN`, `MATRIX_USER_ID`. Every other line in that `.env` is left untouched.
5. `chmod 600` on the target `.env`.
6. Prints what changed -- key names and whether each was added or updated -- **never the token
   value itself**.

Safe to run again: it's idempotent, and each run backs up whatever `.env` was there before
touching it.

### 3. Start rumi-platform on Node 24+ for end-to-end encryption

```bash
cd /path/to/your/rumi-platform
node -v   # want >= 24 for E2EE
rumi start
```

Why Node 24: end-to-end encryption needs `@matrix-org/matrix-sdk-crypto-nodejs`, a native module
whose own `package.json` declares `engines.node: ">=24"` -- it ships prebuilt binaries only for
Node 24 and up, and npm silently skips installing it (no error) on Node 20 or 22.
`matrix-connection.js` requires it lazily, inside a `try/catch`, and what happens next depends on
`MATRIX_E2EE` -- a **three-state** setting, not on/off:

| `MATRIX_E2EE` | Module loads fine | Module can't load (Node <24, no prebuild) |
|---|---|---|
| unset / `auto` (default) | encryption on | logs a warning, **downgrades to plaintext**, keeps running |
| `on` | encryption on | logs the same warning, then **startup fails** (throws) -- an operator who explicitly asked for encryption is never silently handed plaintext |
| `off` | encryption skipped entirely, no attempt made | (module is never touched) |

The auto-downgrade warning, on a module-absent host with `MATRIX_E2EE` unset or `auto`:

```
⚠️ Matrix: E2EE crypto module (@matrix-org/matrix-sdk-crypto-nodejs) is not installed on this host --
it needs Node >=24 with a matching prebuilt native binary. Set MATRIX_E2EE=off to silence this
warning if plaintext is expected, or install it under Node 24+ to enable encryption.
```

On Node 24+ with the module present, rooms the bot creates are encrypted at creation time and no
warning appears. Set `MATRIX_E2EE=off` explicitly if you want plaintext on purpose (e.g. a demo
where you want to inspect message content on the homeserver) -- that skips the load attempt and
the warning both. Set `MATRIX_E2EE=on` if you want a misconfigured deployment to refuse to start
rather than quietly serve plaintext.

### 4. Prove the roundtrip

```bash
MATRIX_HOMESERVER_URL=http://localhost:8008 \
MATRIX_ACCESS_TOKEN=<the token from deploy/rumi-channel.env> \
MATRIX_SMOKE_TARGET_USER=@yourself:localhost \
node bot/scripts/matrix-smoke.js
```

`@yourself:localhost` needs to be a real account on your homeserver, logged into Element (see
[Quick Start](../README.md#quick-start) to create one). The script sends that account a message
from `@rumi`, waits up to 60 seconds for any reply, and prints the exact payload the inbound
adapter produced from it -- the same shape every other channel's messages arrive in. Exit code 0
means the roundtrip is confirmed end to end: send -> Synapse -> sync -> decrypt (if E2EE is on)
-> adapter -> Meta-shaped payload.

## Env var reference

Copied from rumi-platform's `.env.template` `MATRIX_*` block:

| Variable | Required | Default | What it's for |
|---|---|---|---|
| `MATRIX_HOMESERVER_URL` | yes | -- | Your homeserver's client-server API URL, e.g. `http://localhost:8008` locally, `https://chat.yourschool.org` in production. |
| `MATRIX_ACCESS_TOKEN` | yes | -- | The `@rumi` bot account's access token. From `deploy/rumi-channel.env`, written by `scripts/setup.sh`. |
| `MATRIX_USER_ID` | no | resolved via `whoami` on connect | The bot's own Matrix user id, e.g. `@rumi:example.org`. Set explicitly to skip one API call at startup. |
| `MATRIX_STORAGE_DIR` | no | `./.matrix-storage` | Where sync state and the E2EE crypto store persist, relative to the bot process's working directory. Back this up like any other bot state -- losing it loses Olm/Megolm session state, not just a cache. |
| `MATRIX_E2EE` | no | unset (`auto`) | `auto` (or unset) tries E2EE and quietly downgrades to plaintext if the module can't load; `on` requires it and fails startup instead of downgrading; `off` skips the attempt entirely. See [step 3](#3-start-rumi-platform-on-node-24-for-end-to-end-encryption) above. |
| `MATRIX_WELCOME_ROOM_ALIAS` | no | `#rumi-announcements:<bot's own server name>` | The room the bot watches for new-account joins to send the welcome DM. Only set this if you renamed the announcements room. |

## What teachers see

1. A teacher registers on your Element instance (or is invited via a registration token -- see
   [RUNBOOK.md](RUNBOOK.md#registration-modes)).
2. Synapse auto-joins them into `#rumi-announcements`.
3. Within moments, `@rumi` opens a 1:1 chat and sends one line: *"Hi, we're glad you're here. This
   is your space with Rumi. Ask us anything about your class, your lessons, or your day. You're
   not teaching alone."*
4. From there it's an ordinary conversation -- the teacher asks a question, Rumi answers, using
   the exact same coaching, reading-assessment, lesson-plan, and quiz features that exist on
   WhatsApp, Slack, and Discord today. Interactive menus (language picker, feature menu, style
   picker) render as a numbered list they reply to by number or name, since Matrix has no native
   button/list widget most clients render consistently -- the same degraded-but-working pattern
   Baileys already uses for WhatsApp's own linked-device mode.
