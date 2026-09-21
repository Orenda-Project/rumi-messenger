# Rumi Messenger

A self-hosted, end-to-end encrypted messenger for school teams, with Rumi -- the teaching
companion -- one tap away for every teacher. It exists because Meta starts billing WhatsApp
service messages on 1 October 2026: this is what a Rumi deployment moves to instead of paying
per message.

## Why Matrix, not Signal

Signal's server can't be self-hosted past registration -- contact discovery runs in an Intel SGX
enclave, and `storage-service`, SVR2, and zkgroup all depend on infrastructure Signal operates
and doesn't publish. Matrix gives the same shape -- a store-and-forward homeserver that never
sees plaintext in encrypted rooms, keys held only on clients, multi-device support -- but every
piece of it is documented and runnable on hardware you control. Full comparison, including what a
self-hosted Signal-Server would actually be missing: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#appendix-what-signal-server-would-have-needed).

## Quick start (about 5 minutes)

```bash
git clone https://github.com/Orenda-Project/rumi-messenger.git
cd rumi-messenger
scripts/setup.sh
```

`setup.sh` needs only Docker (with the Compose plugin), curl, python3, and openssl -- nothing
else to install first. It brings up Postgres and Synapse, creates an admin account and the
`@rumi` bot account, creates `#rumi-announcements`, and starts a branded Element Web. It's safe
to re-run any time -- every step is idempotent.

When it finishes, it prints something like:

```
================================================================
 Rumi Messenger is up
================================================================
 Element Web:   http://127.0.0.1:8082
 Synapse:       http://127.0.0.1:8008
 Server name:   localhost

 Admin account:   admin
   password (generated, shown once): <a random string -- save it>
 Bot account:     @rumi:localhost (credentials in deploy/rumi-channel.env)
================================================================
```

Open the Element Web URL, click **Create Account**, and register a normal user (not the admin
account -- that's for server administration, see [docs/RUNBOOK.md](docs/RUNBOOK.md)). What you
should see: you land in `#rumi-announcements`, and within a few seconds `@rumi` opens a direct
message and says hello. That's the whole loop -- registration, the shared announcements room, and
Rumi reaching out first -- working end to end on your own machine.

Run `scripts/e2e.sh` any time to verify the stack for yourself instead of taking the above on
faith -- it registers two throwaway accounts, checks the auto-join, and round-trips a real message
both between them and with `@rumi`.

### Ports and multiple deployments

The defaults above (`8008`/`8082` internally, `127.0.0.1` only) are fine for one local checkout.
To change ports, or to run a second, fully independent copy of this stack alongside another
checkout, export these before your *first* `scripts/setup.sh` run (or set them in `deploy/.env`
directly -- either way, `setup.sh` is idempotent, so a later change to one of these on a rerun
just rebinds/renames rather than erroring):

| Variable | What it changes | Default |
|---|---|---|
| `SYNAPSE_PORT` | host port Synapse's client-server API binds to | `8008` |
| `ELEMENT_PORT` | host port Element Web is served on | `8082` |
| `BIND_ADDR` | address those ports bind to (`0.0.0.0` when fronting with Caddy/TLS) | `127.0.0.1` |
| `COMPOSE_PROJECT_NAME` | Docker Compose project name -- gives a second checkout its own volumes/network | `rumi-messenger` |
| `RUMI_CONTAINER_PREFIX` | container name prefix (`<prefix>-postgres`/`-synapse`/`-element`/`-caddy`) -- does not need to match `COMPOSE_PROJECT_NAME` | `rumi` |

Example, a second checkout running side by side with the default one:

```bash
SYNAPSE_PORT=8208 ELEMENT_PORT=8283 \
COMPOSE_PROJECT_NAME=verify2 RUMI_CONTAINER_PREFIX=verify2 \
scripts/setup.sh
```

## How Rumi connects

The homeserver and Element here don't do any teaching on their own -- `@rumi` is a bot account
that [rumi-platform](https://github.com/Orenda-Project/rumi-platform) logs into, the same way it
already logs into Slack and Discord as additional channels alongside WhatsApp. Connecting your
own rumi-platform deployment to this stack is three commands, covered start to finish in
[docs/RUMI-INTEGRATION.md](docs/RUMI-INTEGRATION.md).

## Architecture

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

Full data-flow walkthrough (what happens on a teacher's message, and on Rumi's reply, down to
which process and which API call): [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Features -- honestly, including the gaps

| | Status |
|---|---|
| Self-hosted homeserver, your own domain | Yes -- Synapse + Postgres, one command |
| End-to-end encryption | Yes on the client side (Olm/Megolm), automatic in Element. On the Rumi side, E2EE needs **Node 24+** in rumi-platform (`@matrix-org/matrix-sdk-crypto-nodejs` declares `engines.node: ">=24"` and has no prebuilt binary below that) -- on an older Node, leaving `MATRIX_E2EE` unset auto-downgrades to plaintext with a clear warning instead of crashing; setting it to `on` explicitly makes startup fail loudly instead, so an operator who asked for encryption is never silently handed plaintext. See [docs/RUMI-INTEGRATION.md](docs/RUMI-INTEGRATION.md#3-start-rumi-platform-on-node-24-for-end-to-end-encryption) |
| 1:1 chat, groups, DMs | Yes -- ordinary Matrix rooms |
| Rumi as a first-class contact | Yes, two independent paths: server-side, new accounts auto-join `#rumi-announcements` and Rumi DMs them first; client-side, the logged-in home page's primary button is "Talk to Rumi" (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#the-welcome-dm-mechanism) for why this isn't the client-side `welcome_user_id` feature you may have read about -- Element removed it) |
| Phone-number identity / "find teachers by number" | **No.** Accounts are Matrix user ids, not phone numbers -- there's no contact-discovery-by-phone-number the way WhatsApp has. See [docs/MOBILE.md](docs/MOBILE.md#the-honest-limits) |
| Mobile apps | No dedicated Rumi app. Element X (iOS/Android) or FluffyChat point at your server and work fully, including talking to Rumi -- see [docs/MOBILE.md](docs/MOBILE.md) |
| Push notifications on mobile | Needs your own Sygnal instance + FCM/APNs keys, or UnifiedPush -- not built by `setup.sh`. Without it, clients still sync, just not silently in the background. See [docs/MOBILE.md](docs/MOBILE.md#push-notifications) |
| TLS / a real public domain | Yes -- the `tls` Compose profile fronts everything with Caddy. See [docs/RUNBOOK.md](docs/RUNBOOK.md#moving-to-a-real-domain-tls) |
| Federation with other Matrix servers | Out of scope for v1 (documented in [docs/PLAN.md](docs/PLAN.md)) -- this is a closed messenger for your own team, not a federated network |

## Repo map

```
rumi-messenger/
├── deploy/                  # The stack: Compose file, Synapse data dir, Element config/branding, Caddy
│   ├── docker-compose.yml   # postgres + synapse + element (+ optional caddy under the "tls" profile)
│   ├── .env.example         # every setting setup.sh reads/generates, documented inline
│   ├── element/             # config.template.json + welcome.template.html/home.template.html (rendered by setup.sh), brand assets
│   └── synapse/data/        # homeserver.yaml, signing key, media store -- generated, gitignored, chmod 600
├── scripts/
│   ├── setup.sh             # one-command bring-up, idempotent
│   ├── e2e.sh               # end-to-end verification -- registers real accounts, round-trips real messages
│   ├── logs.sh               # tail one or all services
│   ├── backup.sh             # pg_dump + media_store archive
│   ├── reset.sh               # destroys the local stack (typed confirmation required)
│   └── connect-rumi.sh       # wires deploy/rumi-channel.env into a rumi-platform checkout's .env
└── docs/
    ├── PLAN.md               # the original build plan
    ├── DECISIONS.tsv         # append-only decision log (ts, phase, decision, why, evidence, result)
    ├── ARCHITECTURE.md        # components, data flow, identity format, scaling notes
    ├── RUNBOOK.md             # day-2 ops: start/stop, backup/restore, upgrades, registration, users, rate limits
    ├── LOGGING.md             # every log surface, what's deliberately not logged, correlation
    ├── RUMI-INTEGRATION.md    # connecting a rumi-platform deployment, step by step
    └── MOBILE.md              # Element X / FluffyChat, push notifications, honest limits
```

## Logging

Every container logs JSON (or, for Element's static file server, plain nginx access lines) to
`docker logs` -- there's no separate log file anywhere in `deploy/`. `scripts/logs.sh` tails one
service or all of them. On the rumi-platform side, every Matrix send and receive logs one
structured line with `channel`/`direction`/`roomId`/`eventId`/`type` and never a message body or a
token. Full reference, including what a healthy line looks like and how to correlate a message
across both systems: [docs/LOGGING.md](docs/LOGGING.md).

## License

Apache License 2.0 -- see [LICENSE](LICENSE). Contributions welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md). Security issues: see [SECURITY.md](SECURITY.md), not a public
issue.
