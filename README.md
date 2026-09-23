# Rumi Messenger

A private, end-to-end encrypted messenger for school teams. Teachers chat and call each other,
and Rumi, the teaching companion, is one tap away, just as on WhatsApp. The school runs it on its
own server. Meta starts billing WhatsApp service messages on 1 October 2026, and this is what a
Rumi deployment can move to instead of paying per message.

## Download the app

- **Android:** [download the latest Rumi APK](https://github.com/Orenda-Project/element-x-android/releases/latest) -- `arm64-v8a` for most phones, `universal` if unsure. On first launch, change the server and type your school server's address (`http(s)://your-school-server`).
- **Web:** open your school server's URL in any browser.
- **iOS:** not available yet.

## Start here

| I am... | Read |
|---|---|
| **A teacher.** I want to install the app, sign in and talk to Rumi. | [Teacher guide](docs/TEACHER-GUIDE.md) |
| **The person who runs my school's IT.** I want to set up the server and add teachers. | [Admin guide](docs/ADMIN-GUIDE.md) |
| **A developer.** I want to know how it works or to contribute. | [Architecture](docs/ARCHITECTURE.md), [Plan](docs/PLAN.md), [Decisions log](docs/DECISIONS.tsv), [Runbook](docs/RUNBOOK.md), [Contributing](CONTRIBUTING.md) |

## What it is

Rumi Messenger works like WhatsApp for a school. Teachers sign in with their phone number, chat
and call each other, and Rumi is already there as a contact: they ask for help and get lesson
ideas, quizzes and coaching the same way they do on WhatsApp. It's end-to-end encrypted, and it
runs on a server the school controls. Under the hood it's the open [Matrix](https://matrix.org)
protocol: a Synapse server, the Element apps, and Rumi
([rumi-platform](https://github.com/Orenda-Project/rumi-platform)) connected as an ordinary account.

**Why Matrix, not Signal:** Signal's server can't be self-hosted past registration. Contact
discovery depends on an Intel SGX enclave, and its storage services run on infrastructure Signal
doesn't publish. Matrix gives the same shape: a server that never sees the plaintext of encrypted
messages, keys kept only on devices, and multiple devices per person. Every piece of it is
documented and runs on your own hardware.
[Full comparison](docs/ARCHITECTURE.md#appendix-what-signal-server-would-have-needed).

## Try it in five minutes (for admins and developers)

```bash
git clone https://github.com/Orenda-Project/rumi-messenger.git
cd rumi-messenger
scripts/setup.sh      # needs only Docker (with Compose), curl, python3, openssl
scripts/e2e.sh        # proves it: real accounts, real messages, one PASS/FAIL line per check
```

`setup.sh` starts the server, the web app and the call relay on `127.0.0.1`. It creates an admin
account and the `@rumi` account, and prints the web app's address. It's safe to run again. The
[Admin guide](docs/ADMIN-GUIDE.md) takes you from there to a real school deployment.

![A teacher asks Rumi for a fractions idea and Rumi answers, in the Rumi Android app](docs/img/teacher-4-ask-rumi.png)

## What works today

Tested means we ran it and have the output or the screenshots, not that we expect it to work.

| | Status |
|---|---|
| One-command server (Synapse, Postgres, branded Element Web) | **Tested.** `scripts/e2e.sh` passes every check |
| End-to-end encrypted chat | **1:1 chat tested** in the web app and the Android app. Groups are ordinary Matrix rooms, but we haven't tested them separately yet |
| Rumi as a contact: welcome invitation, questions, quizzes, numbered menus | **Tested** in the web app and the Android app (emulator) |
| Rumi's media features (coaching, reading assessment, photo lesson plans, voice notes) | **Not tested yet** on this channel. The code path exists in [rumi-platform#104](https://github.com/Orenda-Project/rumi-platform/pull/104) |
| Lesson plans | **Blocked** on a Gamma API key ([#11](https://github.com/Orenda-Project/rumi-messenger/issues/11)) |
| Phone number as username, accounts created by the admin | **Tested** (`scripts/teacher.sh`, [#5](https://github.com/Orenda-Project/rumi-messenger/issues/5)). The sign-up page hint is wrong: [#18](https://github.com/Orenda-Project/rumi-messenger/issues/18) |
| Find colleagues by name | **Tested** ([#10](https://github.com/Orenda-Project/rumi-messenger/issues/10)) |
| Android app | **Builds, signs in and talks to Rumi on an emulator.** Real phones not tested yet ([#4](https://github.com/Orenda-Project/rumi-messenger/issues/4)); first public release being published ([#9](https://github.com/Orenda-Project/rumi-messenger/issues/9)) |
| iPhone app | **No.** Use the web app or stock Element X ([#13](https://github.com/Orenda-Project/rumi-messenger/issues/13)) |
| Adding a second device | **Works** with a recovery key. The warning screen is scary ([#14](https://github.com/Orenda-Project/rumi-messenger/issues/14)); stale devices can block sending, and `scripts/devices.sh` fixes that |
| Rumi's replies verified (no red shield) | **Tested** (`scripts/bot-cross-sign.sh`, [#15](https://github.com/Orenda-Project/rumi-messenger/issues/15)) |
| 1:1 voice and video calls | **Relay tested on one machine.** Calls across two real networks need a live domain ([#1](https://github.com/Orenda-Project/rumi-messenger/issues/1), [#6](https://github.com/Orenda-Project/rumi-messenger/issues/6)) |
| Group calls and screen sharing | **Tested** on one machine: two- and three-person video calls and screen share in Element Call ([#2](https://github.com/Orenda-Project/rumi-messenger/issues/2), [CALLING.md](docs/CALLING.md)). Calls between different networks still need a real domain ([#6](https://github.com/Orenda-Project/rumi-messenger/issues/6)) |
| Phone notifications while the app is closed | **No.** Gateway built, no Firebase key yet ([#3](https://github.com/Orenda-Project/rumi-messenger/issues/3), [PUSH.md](docs/PUSH.md)) |
| Real domain with HTTPS | **Tested with a self-signed certificate.** Not yet on a real public domain ([#6](https://github.com/Orenda-Project/rumi-messenger/issues/6)) |
| Backups | **Tested.** Every backup restore-verifies itself (`scripts/backup.sh`) |
| Federation with other servers | **Off by design** ([#8](https://github.com/Orenda-Project/rumi-messenger/issues/8)) |

Everything still open: [issues](https://github.com/Orenda-Project/rumi-messenger/issues).

## How Rumi connects

Synapse and Element don't teach anything on their own. `@rumi` is an ordinary account that
[rumi-platform](https://github.com/Orenda-Project/rumi-platform) signs in to. It is an extra
channel alongside WhatsApp, Slack and Discord, so Rumi's features are the same everywhere.
Connecting takes three commands: [docs/RUMI-INTEGRATION.md](docs/RUMI-INTEGRATION.md).

```text
 Teacher (Rumi Android app / Element Web / Element X)
        |  Matrix client-server API, end-to-end encrypted
        v
 Synapse homeserver  --  Postgres      (+ coturn for calls, Caddy for HTTPS)
        ^
        |  same API, bot account @rumi:<server>
        v
 rumi-platform  --  Matrix channel, next to WhatsApp / Slack / Discord
```

## Built on

Rumi Messenger is a thin layer over other people's hard work. Everything below is used unmodified,
as a pinned official build or a package dependency, and is credited here because the project only
exists because these are open.

| Project | What it does for us | Licence |
|---|---|---|
| [Matrix specification](https://github.com/matrix-org/matrix-spec) | The open protocol the whole thing speaks, which is why Rumi can join as an ordinary account | Apache-2.0 |
| [Synapse](https://github.com/element-hq/synapse) | The homeserver. Stores and delivers messages, never in plaintext | AGPL-3.0 |
| [Element Web](https://github.com/element-hq/element-web) | The app teachers use. We supply the colours, pages and logo through its own configuration | AGPL-3.0 |
| [matrix-bot-sdk](https://github.com/turt2live/matrix-bot-sdk) | How the Rumi channel in rumi-platform talks to the homeserver | MIT |
| [matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk) | The encryption that makes Rumi's own messages end-to-end encrypted | Apache-2.0 |
| [PostgreSQL](https://www.postgresql.org/) | Synapse's database | PostgreSQL licence |
| [Caddy](https://github.com/caddyserver/caddy) | Certificates and the front door, in the `tls` profile | Apache-2.0 |
| [coturn](https://github.com/coturn/coturn) | The TURN relay that makes Element's 1:1 call button work across two real NATs, not just two browser tabs | BSD-3-Clause |

On phones, teachers use [Element X](https://github.com/element-hq/element-x-android) or
[FluffyChat](https://github.com/krille-chan/fluffychat), both AGPL-3.0, pointed at their own server.
Group calls and screen sharing use [LiveKit](https://github.com/livekit/livekit) (Apache-2.0) with
Element's [lk-jwt-service](https://github.com/element-hq/lk-jwt-service) and
[Element Call](https://github.com/element-hq/element-call), under the optional `calls` compose
profile ([CALLING.md](docs/CALLING.md)).

### Contributing back

We would rather send a fix upstream than carry a workaround here. Two things we learned building
this are worth writing up for the projects themselves, and are open for anyone who wants them:

- Element still lists `welcome_user_id` in its configuration documentation as deprecated, but the
  feature was removed. It silently does nothing, which cost us real time. Their docs deserve a
  correction.
- The Compound colour tokens that themes depend on are barely documented. We found all fifty-one by
  inspecting a running build. A documented list would help every self-hoster who brands Element.

If you hit something in this repository that turns out to be an upstream bug, please say so in the
issue, and if you can, report it there too and link it back here.

## Do we fork Element and Synapse?

No. We run their official builds, pinned to exact versions, and hand them our own configuration,
pages and logo. Rumi joins over the Matrix protocol as an ordinary account, so nothing in this
repository is copied from anyone else's project. The reasoning, the licences, and the one case where
a fork would be the right answer are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

The one exception is the Android app. That case has now arrived: the app is a Rumi-branded fork of
[Element X Android](https://github.com/element-hq/element-x-android) (AGPL-3.0), kept at
[Orenda-Project/element-x-android](https://github.com/Orenda-Project/element-x-android) on the
`rumi-brand` branch ([#9](https://github.com/Orenda-Project/rumi-messenger/issues/9)).

## Ports and multiple deployments

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

## Repo map

```text
rumi-messenger/
├── deploy/        # docker-compose.yml, .env.example (every setting), Element branding, Caddyfile
├── scripts/
│   ├── setup.sh             # one-command bring-up, idempotent, no flags (configure via deploy/.env)
│   ├── e2e.sh               # end-to-end verification
│   ├── teacher.sh           # add a teacher: phone number + real name
│   ├── devices.sh           # list / prune a user's stale devices
│   ├── connect-rumi.sh      # copy @rumi's credentials into a rumi-platform checkout
│   ├── bot-cross-sign.sh    # verify Rumi's device (removes the red shield)
│   ├── backup.sh            # Postgres + media + signing key, restore-verified
│   ├── prod-check.sh        # is the live server actually hardened?
│   ├── push-setup.sh / push-check.sh   # Sygnal push gateway
│   ├── calls-check.sh       # group-calls health check
│   ├── theme-guard.sh       # Rumi colours still applied after an Element bump
│   ├── check-upstream-releases.sh      # weekly: files an issue per outdated pinned image
│   ├── logs.sh              # tail one or all services
│   └── reset.sh             # delete everything (asks you to type RESET)
└── docs/
    ├── TEACHER-GUIDE.md  ADMIN-GUIDE.md        # start here
    ├── RUNBOOK.md                               # every operation, in detail
    ├── ARCHITECTURE.md  PLAN.md  DECISIONS.tsv  # how and why
    ├── RUMI-INTEGRATION.md  MOBILE.md  PUSH.md  CALLING.md
    ├── IDENTITY-MODEL.md  FEDERATION-RETENTION.md  LOGGING.md
    └── img/                                     # screenshots used by the guides
```

## License

Apache License 2.0 -- see [LICENSE](LICENSE). Contributions welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md). Security issues: see [SECURITY.md](SECURITY.md), not a public
issue.
