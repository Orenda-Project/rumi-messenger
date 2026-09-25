# Rumi Messenger on Railway

This page puts a working Rumi Messenger on the internet with real HTTPS, without owning a server
or a domain. You need a Railway account, a laptop with a terminal, and about 20 minutes. At the
end, teachers sign in from the phone app or a browser, chat, and call each other.

Rumi itself (the teaching companion who replies) is **not** part of this page's deployment. The
messenger works on its own. Connecting Rumi is a separate step, done later: see
[step 6](#6-connect-rumi).

[Railway](https://railway.com) is a hosting service: it builds each part of Rumi Messenger from
this repository, runs it, and gives each part its own `https://….up.railway.app` address with a
certificate. You don't manage a machine.

If you already run your own Linux server, use the [Admin guide](ADMIN-GUIDE.md) instead. That
setup has everything, including calls that work on every network. Railway is the quicker path,
with one limit on calls, explained [below](#what-does-not-work-on-railway).

**Proven on 2026-09-25.** `scripts/e2e.sh` passed 19 of 19 checks against the public Railway
addresses. Three teachers chatted in one encrypted room from three separate browsers. A two-person
web call connected, with its media carried over TCP.
The evidence is listed [at the end](#what-we-tested).

## On this page

1. [What gets created](#1-what-gets-created)
2. [Before you start](#2-before-you-start)
3. [Deploy](#3-deploy)
4. [Create the admin, Rumi and the announcements room](#4-create-the-admin-rumi-and-the-announcements-room)
5. [Check it works](#5-check-it-works)
6. [Connect Rumi](#6-connect-rumi)
7. [Add teachers and send them the details](#7-add-teachers-and-send-them-the-details)
8. [Variables](#8-variables)
9. [Costs](#9-costs)
10. [What does not work on Railway](#what-does-not-work-on-railway)
11. [Day-2: update, back up, remove](#11-day-2-update-back-up-remove)

## 1. What gets created

One Railway project called `rumi-messenger`, with six parts. Railway calls each part a service.

| Service | What it is | Its address | Storage |
|---|---|---|---|
| `synapse` | The chat server. Every account and every encrypted message lives here. **This is the address teachers type into the app.** | `https://synapse-….up.railway.app` | volume at `/data` (keys, config, photos) |
| `Postgres` | The chat server's database (Railway's own managed Postgres) | private | Railway-managed volume |
| `element` | The web app teachers open in a browser | `https://element-….up.railway.app` | none |
| `ntfy` | Push notifications for phones, no Google involved ([PUSH.md](PUSH.md)) | `https://ntfy-….up.railway.app` | volume at `/var/lib/ntfy` |
| `livekit` | The calls server | `https://livekit-….up.railway.app`, plus one TCP port for call audio and video | none |
| `lk-jwt` | Issues call tickets to signed-in teachers | `https://lk-jwt-….up.railway.app` | none |

Each service is built from `deploy/railway/<service>/Dockerfile`. It uses the same pinned image as
the self-hosted setup (`deploy/docker-compose.yml`) plus a small start-up script that fills in
the settings from Railway's variables. The Synapse settings come from
`deploy/synapse/patch_homeserver.py`, the same file `scripts/setup.sh` uses, so both setups
configure the server in exactly the same way.

## 2. Before you start

1. **A Railway account.** Sign up at [railway.com](https://railway.com). Deploying needs a plan
   with a payment method: a workspace without one is "restricted" and refuses to create services.
   See [costs](#9-costs).
2. **The Railway CLI** on your laptop, version 5 or newer. Follow
   [Railway's install page](https://docs.railway.com/cli), then check that `railway --version`
   prints a version.
3. **This repository**, plus `python3`, `curl` and `openssl`, which most Linux and macOS
   machines already have. `scripts/railway-deploy.sh` runs on macOS's built-in bash 3.2 too, so you don't need a newer bash from Homebrew:

   ```bash
   git clone https://github.com/Orenda-Project/rumi-messenger.git
   cd rumi-messenger
   ```

4. **Sign in to Railway from the terminal.** This opens a browser:

   ```bash
   railway login
   railway whoami        # should print your name
   ```

## 3. Deploy

**Decide first:** the chat server's address becomes part of every teacher's username
(`@+923001234567:synapse-….up.railway.app`), and **it can't be changed later**. It is fixed
the first time Synapse starts. Moving to your own domain later means a new, empty server. The
start-up script refuses to boot if the address ever changes under it, so accounts can't be
quietly corrupted. For a pilot, the Railway address is fine.

Run one command from the repository folder:

```bash
scripts/railway-deploy.sh
```

If your Railway account has more than one workspace, name the one to use:
`RAILWAY_WORKSPACE="Your workspace" scripts/railway-deploy.sh`.

The script:

1. Creates the project `rumi-messenger`, or links to it if it already exists.
2. Adds Postgres and the five services.
3. Gives every service its own `https://….up.railway.app` address.
4. Adds the two storage volumes (Synapse at `/data`, ntfy at `/var/lib/ntfy`).
5. Creates the one TCP port that call audio and video use (a Railway "TCP proxy" on the
   `livekit` service).
6. Generates the secrets once and keeps them in two places only: Railway's variables and
   `deploy/railway/.env.railway` on your laptop (readable by you only, never committed).
   **Back that file up.** It holds the admin password.
7. Builds and starts each service (`railway up`) from this folder. The build logs stream in
   your terminal, and each service ends with `Deploy complete`.

It's safe to run again. It only creates what's missing, then redeploys. The first run takes about
5 minutes. Run `railway service list` afterwards: all six services should say **Online**.

## 4. Create the admin, Rumi and the announcements room

```bash
scripts/railway-bootstrap.sh
```

This runs from your laptop against the public server. It creates the `admin` account and the
`@rumi` account, gives Rumi its name and picture, and makes sure **Rumi Announcements** exists
and is named. It then writes Rumi's login to `deploy/railway/rumi-channel.env`, readable by you
only and never committed. It's safe to run again.

## 5. Check it works

```bash
RUMI_ENV_FILE=deploy/railway/.env.railway scripts/e2e.sh
```

Expect `19 passed, 0 failed`. On Railway, two checks differ from a self-hosted server:

- The push check runs against the public ntfy. Synapse pushes a real message to it over the
  internet, and a listener receives it.
- The two call-relay (coturn) checks become "no relay server is handed out", because Railway has
  none ([why](#what-does-not-work-on-railway)).

Then open the `element` address (`https://element-….up.railway.app`) in a browser. You should see
the Rumi sign-in page.

## 6. Connect Rumi

**Today Rumi is not connected to this Railway deployment.** The messenger works on its own:
teachers sign in, chat and call. Messages to `@rumi` get no reply until Rumi is connected. Step 4
only creates Rumi's *account* and writes its login to `deploy/railway/rumi-channel.env`; nothing
on Railway runs Rumi.

Rumi is a separate program, [rumi-platform](https://github.com/Orenda-Project/rumi-platform). It
talks to this server through its Matrix channel, which is still in review
([rumi-platform#104](https://github.com/Orenda-Project/rumi-platform/pull/104), not merged). It is
a long-running bot, so it has to run somewhere that stays on. Connecting it is the same on Railway
as on a self-hosted server: rumi-platform gets `MATRIX_HOMESERVER_URL`, `MATRIX_ACCESS_TOKEN` and
`MATRIX_USER_ID`, and only the server address differs. Follow [RUMI-INTEGRATION.md](RUMI-INTEGRATION.md),
and when it copies the login, use the Railway one:

```bash
RUMI_CHANNEL_ENV=deploy/railway/rumi-channel.env scripts/connect-rumi.sh /path/to/rumi-platform
```

After Rumi has started once, so that its device exists on the server, remove the red shield from
its replies. This step needs **Node.js 22 or newer** on your laptop (`node --version`). The script
installs matrix-js-sdk 42, which requires Node 22, and its install step runs silently, so an older
Node gives you no warning:

```bash
scripts/railway-bootstrap.sh --cross-sign
```

This writes `deploy/railway/rumi-cross-signing-recovery-key.txt`. **Back it up.** If Rumi ever
gets a new device (a new token, or a lost `.matrix-storage`), run the same command again. It
reloads the keys with the recovery key and signs the new device. We tested this: the bot's
storage was lost mid-test, and the command re-signed its replacement device without an identity
reset.

## 7. Add teachers and send them the details

```bash
RUMI_ENV_FILE=deploy/railway/.env.railway scripts/teacher.sh add "+923001112233" "Ayesha Khan"
```

Everything in [Admin guide section 5](ADMIN-GUIDE.md#5-add-teachers) applies, including the CSV
loop. Put `RUMI_ENV_FILE=deploy/railway/.env.railway` in front of each command.

Send each teacher:

- **In the phone app:** on first launch, tap **Sign in manually** and change the server to the
  `synapse` address, `https://synapse-….up.railway.app`. It's not the `element` address.
- **In a browser:** the `element` address.
- **Their username** (the phone number with `+`) and **their password**.
- **For notifications:** install the ntfy app (F-Droid build) and set its *Default server* to the
  `ntfy` address, `https://ntfy-….up.railway.app`, **before** opening Rumi
  ([TEACHER-GUIDE](TEACHER-GUIDE.md)).

## 8. Variables

`scripts/railway-deploy.sh` sets all of these. The table lets you check them in the Railway
dashboard (service → Variables). `${{…}}` is Railway's own reference syntax: Railway fills it in
from the other service.

| Service | Variable | Value | Secret? |
|---|---|---|---|
| all five | `RAILWAY_DOCKERFILE_PATH` | `deploy/railway/<service>/Dockerfile` | no |
| all five | `PORT` | synapse `8008`, livekit `7880`, the others `8080`. Each domain points at this port. | no |
| synapse | `DATABASE_URL` | `${{Postgres.DATABASE_URL}}` | yes (by reference) |
| synapse | `REG_SHARED_SECRET` | random, generated once | **yes** |
| synapse | `LIVEKIT_SERVICE_URL` | `https://${{lk-jwt.RAILWAY_PUBLIC_DOMAIN}}` (leave it out to turn calls off) | no |
| synapse | `SERVER_NAME` | optional. Defaults to the synapse domain and is fixed at first boot. | no |
| element | `SERVER_NAME` | `${{synapse.RAILWAY_PUBLIC_DOMAIN}}` | no |
| livekit | `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | random, generated once | **yes** |
| livekit | `LK_JWT_URL` | `https://${{lk-jwt.RAILWAY_PUBLIC_DOMAIN}}` | no |
| lk-jwt | `LIVEKIT_URL` | `wss://${{livekit.RAILWAY_PUBLIC_DOMAIN}}` | no |
| lk-jwt | `LIVEKIT_KEY`, `LIVEKIT_SECRET` | `${{livekit.LIVEKIT_API_KEY}}`, `${{livekit.LIVEKIT_API_SECRET}}` | yes (by reference) |
| lk-jwt | `LIVEKIT_FULL_ACCESS_HOMESERVERS` | `${{synapse.RAILWAY_PUBLIC_DOMAIN}}` | no |

Railway sets `RAILWAY_PUBLIC_DOMAIN`, `RAILWAY_TCP_PROXY_DOMAIN` and `RAILWAY_TCP_PROXY_PORT` by
itself. ntfy needs no variables beyond `PORT`: its address is its own domain.

Your laptop keeps `deploy/railway/.env.railway` (admin password, Rumi's password, the shared
secret, the four public addresses). Every script above reads it through `RUMI_ENV_FILE`. The file
is gitignored.

## 9. Costs

Railway charges for what runs, per minute, on top of a plan fee. These are Railway's published
prices, [docs.railway.com/reference/pricing/plans](https://docs.railway.com/reference/pricing/plans),
read on 2026-09-25:

- **Plans:** Hobby is $5 a month and includes $5 of usage. Pro is $20 a month and includes $20.
- **Usage:** $10 per GB of memory per month, $20 per vCPU per month, $0.15 per GB of volume
  storage per month, $0.05 per GB of outbound traffic.

What our test deployment actually used while idle, measured with `railway metrics`: about
**0.67 GB of memory** (Synapse 254 MB, Postgres 168 MB, LiveKit 128 MB, Element 60 MB, ntfy 45 MB,
lk-jwt 14 MB) and almost no CPU. That works out to roughly **$7–10 a month** of usage for one
school pilot, before traffic. On the Hobby plan, that's about $5–10 a month in total. Calls and
photos add outbound traffic at $0.05 per GB. An audio call uses tens of MB per hour. Video uses more.

Set a spending limit so a mistake can't surprise you: `railway usage limit --help`.

## What does not work on Railway

Stated plainly, so nobody files these as bugs:

- **Calls are best effort.** Railway carries no UDP traffic at all, and UDP is what calls
  normally use. We run LiveKit with call media over one TCP port instead (Railway's "TCP proxy").
  A two-person web call connected in our test, with both people's audio flowing
  (`connectionType: tcp` in LiveKit's log). Over TCP, on a poor mobile connection, expect more
  delay and choppier sound than on a self-hosted server. Group calls use the same path and have
  had less testing. **For calls you rely on, use a self-hosted server** ([CALLING.md](CALLING.md)).
- **No coturn (TURN relay).** It needs UDP ports that Railway doesn't have. It's omitted, and
  Synapse is told not to hand out a TURN address, so no client is sent to a dead one. LiveKit's
  TCP port does the NAT traversal work for Element Call. The web app's old-style 1:1 calls, which
  are the only calls that use coturn, are switched off (`element_call.use_exclusively`).
- **The server address is fixed.** See [step 3](#3-deploy). Switching to your own domain later is
  a new server, not a rename.
- **Admin API on the public address.** Self-hosted setups can hide `/_synapse/admin` behind
  Caddy. On Railway there is no proxy of ours in front of Synapse, so the admin API is reachable
  from the internet. It still requires an admin login, and account creation still requires the
  shared secret. Keep the admin password long, and don't use the admin account day to day.
  Every admin password login creates a new admin session (a full-power token). The scripts log
  theirs out when they finish. If you log in by hand, log out afterwards:
  `curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" $SYNAPSE_URL/_matrix/client/v3/logout`.
  To see or clear leftover admin sessions, see "Admin sessions" in [RUNBOOK.md](RUNBOOK.md#admin-sessions-dont-leave-tokens-behind).
- **Someone holding a sign-up token can still learn whether a phone number has an account.**
  Usernames are phone numbers. Without a login, the server no longer says whether a number is
  taken: "is this username free?" (`/register/available`) always answers yes, sign-up only reports
  a taken name after the one-time token has been accepted, and profiles (display names) need a
  login (`inhibit_user_in_use_error` and `require_auth_for_profile_requests`, set in
  `deploy/synapse/patch_homeserver.py`). What's left: someone who has a valid registration token,
  or any signed-in teacher (the directory search is meant to find colleagues), can still find out.
  Wrong-password logins give the same answer for real and made-up numbers and are rate limited.
  Treat the teacher list as known to staff, and give out registration tokens one at a time.
- **One copy of each service.** Synapse writes to its volume, so you can't scale it to several
  replicas. A school pilot doesn't need to.

## 11. Day-2: update, back up, remove

- **Update** after a `git pull`: `scripts/railway-deploy.sh` rebuilds and redeploys every
  service. `SERVICES="element" scripts/railway-deploy.sh` redeploys just one.
- **Logs:** `railway logs --service synapse` (or any other service name).
- **Back up.** Railway reaches the database and the volumes over SSH, so register your laptop's
  SSH key with Railway **once**. Without it, every command below fails with "No registered SSH keys
  found":

  ```bash
  railway ssh keys add       # once per laptop. No key yet? Run ssh-keygen -t ed25519 first.
  railway ssh keys list      # shows the key
  ```

  Then, from the repository folder, make one backup folder outside the repository and fill it:

  ```bash
  B="$HOME/rumi-backup-$(date +%F)"; mkdir -p "$B"
  # 1. The database: every account and message. It is called "synapse", not "railway".
  railway ssh --service Postgres -- pg_dump -U postgres -Fc synapse > "$B/synapse.dump"
  # 2. Synapse's volume: the signing key, homeserver.yaml, uploaded photos.
  railway volume files --volume synapse-volume download / "$B/synapse-volume"
  # 3. ntfy's volume: which phones get notifications.
  railway volume files --volume ntfy-volume download / "$B/ntfy-volume"
  # 4. Your laptop's secrets (the admin password and the shared secret are in .env.railway).
  cp -p deploy/railway/.env.railway "$B/"
  cp -p deploy/railway/rumi-channel.env deploy/railway/rumi-cross-signing-recovery-key.txt "$B/" 2>/dev/null || true
  chmod -R go-rwx "$B"
  ls -laR "$B" | head -40
  ```

  `pg_dump` runs *inside* Railway's Postgres, so you need nothing extra installed, and the dump
  matches the server's Postgres version. It is not a command you type into `psql`. The volume names
  come from `railway volume list`. `--volume` goes straight after `files`. Without it, the command
  stops to ask which volume you mean.

  Check what you got. For a small pilot, `synapse.dump` is about 1 MB, and it grows with messages.
  The files that matter most:

  | File in the backup | What it is | If you lose it |
  |---|---|---|
  | `synapse.dump` | the database: accounts, rooms, messages | **Everything is gone.** |
  | `synapse-volume/<server address>.signing.key` | the server's signing key | Messages survive. Put this copy back, with `railway volume files --volume synapse-volume upload`. |
  | `synapse-volume/homeserver.yaml` | Synapse's settings, including three secrets (`registration_shared_secret`, `macaroon_secret_key`, `form_secret`) | Put this copy back the same way. The start-up script re-applies its settings on every boot. |
  | `rumi-cross-signing-recovery-key.txt` | Rumi's cross-signing recovery key (exists only after [step 6](#6-connect-rumi)) | Rumi's identity has to be reset, and teachers see a warning. |

  The backup holds secrets. Keep it off shared drives. To check that a dump is readable:
  `pg_restore --list "$B/synapse.dump" | head` (this needs a local `pg_restore` of version 18 or
  newer). Or restore it into a scratch `postgres:18` container.
- **Remove everything:** `railway delete --project rumi-messenger --yes`. This deletes the
  database and all messages permanently.

## What we tested

On 2026-09-25, against `https://synapse-production-0d99.up.railway.app` and
`https://element-production-1879.up.railway.app`:

| What | Result |
|---|---|
| All five images build locally, then run as a Railway-shaped stack (`deploy/railway/compose.local.yml`, Postgres at its default non-C locale like Railway's) | Built and ran, 18/19. The one failure was the call-ticket check: the local stack's made-up server name has no public DNS, so lk-jwt couldn't look it up. On Railway the name is real, and the check passes. |
| `scripts/e2e.sh` against the public Railway addresses | **19/19** |
| `scripts/e2e.sh` on the self-hosted dev stack after these changes | **19/19** (unchanged) |
| `scripts/teacher.sh` against the public server | Accounts created and joined to Rumi Announcements |
| Three teachers in one encrypted room, each in their own browser session on the public web app | Each saw all three messages, none undecryptable |
| Rumi's greeting to a new teacher (web) | Arrived and decrypted, but **not from a connected Rumi**. It came from a temporary test script on a laptop that ran only rumi-platform's Matrix welcome code (PR #104), greeted new accounts and never answered. It proves the channel code works against this server, not that Rumi is live here. Rumi is not connected ([step 6](#6-connect-rumi)). |
| Backup (`railway ssh` + `railway volume files`, [day-2](#11-day-2-update-back-up-remove)) | Run exactly as written above: `synapse.dump` 1.31 MB, restored into `postgres:18` with the same counts as live (67 users, 940 events, 84 rooms). synapse-volume 304 KB (signing key, homeserver.yaml, 7 media files). ntfy-volume 200 KB (two SQLite files, integrity ok). |
| Two-person web call (one calls, the other joins) | Both connected to LiveKit, both published audio, `connectionType: tcp` |
| Push: Synapse → public ntfy → a listener | Delivered (e2e check) |
| Phone app (release v0.1.5) signs in to the public server | The sign-in reached the server and registered the phone as a device. The Android **emulator** on our test laptop then crashed while drawing the chat list. That's a known problem with this laptop's emulator (it crashed the same way with stock Element X on 2026-09-23). It's not a server problem. It still needs a check on a real phone: sign-in, and a notification with the app closed. Rumi's greeting on the phone can only be checked once Rumi is connected. |
