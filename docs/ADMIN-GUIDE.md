# Admin guide

This guide is for the person who runs the school's IT. It takes you from nothing to a working
Rumi Messenger that teachers sign in to with their phone number, with Rumi answering inside it.
You don't need to know Matrix beforehand. You do need to be comfortable with a Linux terminal,
Docker and DNS.

Teachers get their own guide: [TEACHER-GUIDE.md](TEACHER-GUIDE.md). Once you've created their
accounts, send them that link.

## On this page

1. [What you are setting up](#1-what-you-are-setting-up)
2. [Requirements](#2-requirements)
3. [Ten-minute trial on one machine](#3-ten-minute-trial-on-one-machine)
4. [Go live on a real domain](#4-go-live-on-a-real-domain)
5. [Add teachers](#5-add-teachers)
6. [Connect Rumi](#6-connect-rumi)
7. [Push notifications](#7-push-notifications)
8. [Calls](#8-calls)
9. [Backups](#9-backups)
10. [Upgrades](#10-upgrades)
11. [Security checklist](#11-security-checklist)
12. [Day-to-day fixes](#12-day-to-day-fixes)
13. [Getting help](#13-getting-help)

## 1. What you are setting up

| Piece | What it does | Where it runs |
|---|---|---|
| **Synapse** + **Postgres** | The chat server. It stores encrypted messages and delivers them. | Docker, on your server (this repo) |
| **Element Web** | The web app teachers open in a browser, with Rumi branding | Docker, on your server (this repo) |
| **coturn** | Relays voice and video calls between different networks | Docker, on your server (this repo) |
| **Caddy** | HTTPS certificates and the single public front door | Docker, on your server (this repo, `prod` profile) |
| **rumi-platform** | Rumi itself. It signs in as the `@rumi` account and answers teachers | A Node.js service, on your server or elsewhere ([rumi-platform](https://github.com/Orenda-Project/rumi-platform)) |
| **The Android app** | What teachers install on their phones | [element-x-android releases](https://github.com/Orenda-Project/element-x-android/releases/latest) |

One server serves one school. Every account on it can find every other account by name, so don't
put two schools on one server. The [RUNBOOK privacy note](RUNBOOK.md#teacher-directory-search-start-chat-finds-a-colleague-by-name)
explains why.

## 2. Requirements

- **A Linux server.** A cloud VPS or a machine at school, with a public IP address for going live.
  For one school, start with 2 CPU cores, 4 GB RAM and 40 GB disk. That is our estimate, not a
  measured figure. Media uploads (limit 50 MB each) are what grows the disk.
- **Software:** Docker with the Compose plugin, `git`, `curl`, `python3` and `openssl`. `setup.sh`
  needs nothing else. On a fresh Ubuntu or Debian server, install them like this:

  ```bash
  sudo apt-get update && sudo apt-get install -y git curl python3 openssl
  curl -fsSL https://get.docker.com | sudo sh    # Docker's official install script, includes Compose
  sudo usermod -aG docker "$USER"                # then log out and back in
  docker compose version                         # must print a version, not an error
  ```

  For other systems, see [Docker's install docs](https://docs.docker.com/engine/install/).
- **A domain name** you control, such as `chat.yourschool.org`, plus the ability to add a DNS `A`
  record. You only need it to go live, not for the trial.
- **Open firewall ports** (going live only): TCP 80 and 443, TCP+UDP 3478, UDP 49152-65535
  (coturn), and for calls TCP 7881 plus UDP 50100-50200 (LiveKit media).
  The [RUNBOOK port table](RUNBOOK.md#ports-to-open-on-the-servers-firewall--cloud-security-group)
  explains each one.
- **For Rumi:** Node.js 24 or newer, a rumi-platform checkout and its accounts (Supabase,
  OpenRouter, Redis). See [section 6](#6-connect-rumi).

## 3. Ten-minute trial on one machine

This runs everything on `127.0.0.1` so you can see it work before you commit to a domain.
Nothing is reachable from other machines.

```bash
git clone https://github.com/Orenda-Project/rumi-messenger.git
cd rumi-messenger
scripts/setup.sh
```

`setup.sh` takes no command-line options.
Running it restarts Synapse and recreates the web app and call relay containers. On a live
server, expect a few seconds of interruption each time, while teachers' apps reconnect by
themselves. Configure it with environment variables or with
`deploy/.env` (every setting is documented in `deploy/.env.example`). It is safe to run again
at any time. When it finishes, it prints:

```text
 Element Web:   http://127.0.0.1:8082
 Synapse:       http://127.0.0.1:8008
 Server name:   localhost
 Admin account:   admin
   password (generated, shown once): <save this>
 Bot account:     @rumi:localhost (credentials in deploy/rumi-channel.env)
```

Save the admin password. It is also stored in `deploy/.env` as `ADMIN_PASSWORD`.

**Check that it works:**

```bash
scripts/e2e.sh
```

This creates two throwaway accounts, sends real messages between them, checks the Rumi welcome
room, the colleague search and the call relay, and prints one `PASS`/`FAIL` line per check. It
exits non-zero if anything fails.

**Try it as a teacher:**

```bash
scripts/teacher.sh add "+923001234567" "Test Teacher" --password trial-pass-1
```

Open `http://127.0.0.1:8082`, click **Sign in** and use `+923001234567` / `trial-pass-1`. Rumi's
invitation only arrives if Rumi is connected ([section 6](#6-connect-rumi)). Without Rumi, you
can still test chat between two teacher accounts.

**Ports already in use?** Set `SYNAPSE_PORT`, `ELEMENT_PORT`, `COMPOSE_PROJECT_NAME` and
`RUMI_CONTAINER_PREFIX` before the first run, as shown in
[README: Ports and multiple deployments](../README.md#ports-and-multiple-deployments).

**Throw the trial away** before going live. The trial's server name (`localhost`) is baked into
every account and can't be changed afterwards:

```bash
scripts/reset.sh     # asks you to type RESET; deletes all data, no undo
```

## 4. Go live on a real domain

**If you ran the trial on this same server, run `scripts/reset.sh` first.** The trial's
`localhost` accounts can't be moved to your domain.

The go-live procedure lives in one place, the RUNBOOK. Follow
[Going live on a real domain: the checklist](RUNBOOK.md#going-live-on-a-real-domain-issue-6----the-actual-checklist)
from top to bottom. In short:

1. **Choose the domain first.** `SERVER_NAME` becomes part of every teacher's username
   (`@+923001234567:chat.yourschool.org`), and it can't be changed later without wiping the server.
2. Add a DNS `A` record pointing the domain at your server, and wait until `dig +short chat.yourschool.org`
   returns the right IP.
3. In `deploy/.env`, set `SERVER_NAME=chat.yourschool.org`,
   `PUBLIC_BASE_URL=https://chat.yourschool.org` and `REGISTRATION_MODE=token`. Leave
   `BIND_ADDR=127.0.0.1`. Caddy is the only thing that should face the internet
   ([why](RUNBOOK.md#moving-to-a-real-domain-tls)).
4. Run `scripts/setup.sh`, then `cd deploy && docker compose --profile prod up -d` to start
   Caddy. Caddy gets a Let's Encrypt certificate by itself. To watch it happen, run
   `scripts/logs.sh -s caddy`.
5. Run `scripts/prod-check.sh`. It checks HTTPS, closed registration, that Postgres, Synapse and
   Element aren't exposed directly, and the call-relay hardening. Every check should pass.
6. Open `https://chat.yourschool.org`. You should see the Rumi sign-in page.

Want to prove HTTPS works before DNS exists? Set `CADDY_TLS_MODE=internal` to get a self-signed
certificate. See [RUNBOOK](RUNBOOK.md#moving-to-a-real-domain-tls), and remove the setting
before real use.

> **Coming:** we've proven every step above on one machine with a self-signed certificate. We
> haven't yet run them on a real public domain with a real certificate. Issue
> [#6](https://github.com/Orenda-Project/rumi-messenger/issues/6) stays open until we have. If
> you're the first, please tell us how it went.

**Pilot on the school Wi-Fi without a domain?** You can set `BIND_ADDR=0.0.0.0` and
`PUBLIC_BASE_URL=http://<server's LAN IP>:8008`, and teachers then type that `http://` address in
the app. Treat this as a short pilot only: it's plain HTTP with no certificate, and the Android
app waits about 90 seconds before it falls back to `http://`. We've only tested this on an
emulator ([MOBILE.md](MOBILE.md#two-things-learned-on-the-emulator-23-september-2026)).

## 5. Add teachers

Teachers don't sign up themselves. You create each account, with the phone number as the username:

```bash
scripts/teacher.sh add "+923001112233" "Ayesha Khan"                       # prints a generated password once
scripts/teacher.sh add "+923004445566" "Bilal Ahmed" --password 'S0me-Pass'  # or choose one
```

- The number **must start with `+`** and contain no spaces. The script refuses anything else.
  (Synapse rejects all-digit usernames, see [#18](https://github.com/Orenda-Project/rumi-messenger/issues/18).)
- Use the teacher's real name, because that's what colleagues search for.
- The script also adds the teacher to **Rumi Announcements**. When Rumi is connected, that
  triggers Rumi's welcome invitation.
- Running it again for the same number only updates the name. It never changes the password.

**Many teachers at once**, from a `teachers.csv` file with one `+92...,Full Name` per line:

```bash
while IFS=, read -r phone name; do scripts/teacher.sh add "$phone" "$name"; done < teachers.csv | tee created.txt
```

`created.txt` then holds each generated password. Hand them out privately and delete the file.

**What to send each teacher:** the server address (`https://chat.yourschool.org`), their username
(`+923001112233`), their password, and a link to [TEACHER-GUIDE.md](TEACHER-GUIDE.md).

**Reset a forgotten password.** There's no email reset. Get an admin token first, as shown in
[RUNBOOK: Registration modes](RUNBOOK.md#registration-modes), then:

```bash
curl -s -X PUT "http://127.0.0.1:8008/_synapse/admin/v2/users/%2B923001112233:chat.yourschool.org" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
  -d '{"password":"new-password-here"}'
```

This signs the teacher out on all their devices. After signing back in, each device needs their
recovery key or approval from another device (TEACHER-GUIDE section 8). Use your own port and
server name. The `+` in the URL is written as `%2B`.

**Someone leaves the school:** deactivate the account. See
[RUNBOOK: Creating and deactivating users](RUNBOOK.md#creating-and-deactivating-users).

**Open sign-up (not recommended).** `REGISTRATION_MODE=open` lets anyone who can reach the server
make an account, and `token` needs a one-time code. Both are described in
[RUNBOOK: Registration modes](RUNBOOK.md#registration-modes). If you use either, tell people to
register with the `+` form of their number. The sign-up page currently says the opposite
(issue [#18](https://github.com/Orenda-Project/rumi-messenger/issues/18)).

## 6. Connect Rumi

Rumi is a separate service, [rumi-platform](https://github.com/Orenda-Project/rumi-platform). It
signs in to your server as `@rumi`, the same way it connects to WhatsApp, Slack and Discord.
[RUMI-INTEGRATION.md](RUMI-INTEGRATION.md) covers it step by step. In short:

1. **Get rumi-platform with the Matrix channel.** Until
   [rumi-platform PR #104](https://github.com/Orenda-Project/rumi-platform/pull/104) merges, use
   its `feat/matrix-channel` branch. Open the PR first: if it says **Merged**, use `main`
   instead. Set it up with that repo's own guide (`rumi setup`).
2. **Copy the bot credentials across.** `setup.sh` already wrote them to `deploy/rumi-channel.env`:

   ```bash
   scripts/connect-rumi.sh /path/to/rumi-platform
   ```

   This backs up the target `.env`, then sets `MATRIX_HOMESERVER_URL`, `MATRIX_ACCESS_TOKEN` and
   `MATRIX_USER_ID`. It never prints the token.
3. **Start Rumi on Node 24 or newer** (`node -v`), then run `rumi start`. On Node 24 or newer,
   Rumi's replies are end-to-end encrypted. On older Node versions, the default (`MATRIX_E2EE`
   unset) falls back to plain text with a warning. Set `MATRIX_E2EE=on` to refuse to start
   instead. The [three-state table](RUMI-INTEGRATION.md#3-start-rumi-platform-on-node-24-for-end-to-end-encryption)
   has the details.
4. **Remove the red shield on Rumi's replies.** Run this once, on the server (it needs Node 22 or
   newer):

   ```bash
   scripts/bot-cross-sign.sh
   ```

   It writes `deploy/rumi-cross-signing-recovery-key.txt`. **Back that file up.** Without it, you
   can't sign a future bot device without resetting Rumi's identity, and every teacher would then
   see "Rumi's identity changed". See [RUNBOOK](RUNBOOK.md#rumis-replies-show-a-red-unverified-device-shield-issue-15).
5. **Test it.** Sign in as a teacher. Rumi's invitation should arrive within seconds. Send
   "hello", and a reply should arrive in about 15 seconds.

**Which Rumi features work** depends on the keys you give rumi-platform, exactly as on WhatsApp.
For example, voice, coaching and reading need `SONIOX_API_KEY`, and lesson plans need
`GAMMA_API_KEY`. The full list is in
[rumi-platform's feature table](https://github.com/Orenda-Project/rumi-platform#what-rumi-does).
Buttons and forms show up as numbered menus.

> **Coming:** chat and quizzes have been proven in the Android app and the web app. The media
> features (coaching, reading assessment, photo lesson plans, voice notes) haven't been tested end
> to end on this channel yet. Lesson plans are blocked on a Gamma key
> ([#11](https://github.com/Orenda-Project/rumi-messenger/issues/11)).

**Keep `.matrix-storage` safe.** It's in the rumi-platform working directory and holds Rumi's
encryption state. If you lose it, Rumi can't read older encrypted messages.

## 7. Push notifications

Push runs on our own **ntfy** server, no Google involved. Add a DNS A record for
`ntfy.<your domain>`, run `scripts/push-setup.sh` (starts ntfy under the `push` profile; Caddy
serves it at `https://ntfy.<your domain>`), then `scripts/push-check.sh` (4 checks, all must
pass). Each teacher installs the ntfy app once and points it at that address before opening Rumi
([TEACHER-GUIDE](TEACHER-GUIDE.md#6-chat-and-call-your-colleagues)). One thing to check: Synapse
won't push to a private IP, so `docker exec rumi-synapse getent hosts ntfy.<your domain>` must give
the public IP. A server with no domain uses LAN mode, below.

> **Coming:** the whole chain (message in the background, app force-stopped, incoming call
> ringing) is proven on the emulator with LAN mode, and since app v0.1.4 nothing is hand-set (a
> fresh install of the release APK registered its own LAN pusher); no real phone has run it yet ([#3](https://github.com/Orenda-Project/rumi-messenger/issues/3),
> [PUSH.md](PUSH.md#lan-mode-school-server-on-the-school-wi-fi-no-domain)). The Firebase route
> (Sygnal) is built but has no key.

### School LAN server, no domain

For a box in the school (teachers on the school Wi-Fi, no public domain):

1. Give the box a **fixed IP** (a DHCP reservation on the router), because `LAN_IP` is baked into
   every phone's pusher and into Synapse's push whitelist: when our test laptop moved networks
   (192.168.100.188 -> 10.10.20.230), push broke until `setup.sh` was re-run with the new IP (and
   phones then need their ntfy Default server changed and Rumi's notifications toggled off and on).
2. `LAN_IP` in `deploy/.env`: leave it blank and `setup.sh` picks the box's first IP
   (`hostname -I | awk '{print $1}'`) while `PUBLIC_DOMAIN` is `localhost`. Set it by hand if that
   picks the wrong network card. `LAN_IP=off` turns LAN mode off (then also set
   `BIND_ADDR=127.0.0.1`).
3. Run `scripts/setup.sh`. It starts ntfy on `http://<LAN_IP>:2586`, lets Synapse push to that one
   address (`ip_range_whitelist: ["<LAN_IP>/32"]`, nothing wider, so no teacher can make the
   server call other machines on the school network), and binds the services on every interface.
   `scripts/e2e.sh` then checks a real push reaches ntfy.
4. Open these ports **on the box's firewall, to the school network only**: TCP 8108 (server), 8182
   (web app), 2586 (ntfy), 8180 and 7880 (calls), TCP 7881 + UDP 50100-50200 (call media), TCP+UDP
   3478 (web app 1:1 calls). Never forward them on the router to the internet.
5. Phones and computers must be **on the same network** as the box. From home, nothing works.

What does not work yet over plain http on a LAN, stated plainly:

- **The phone app refuses plain http to a bare IP for sign-in.** Signing in to
  `http://192.168.x.y:8108` fails. A router DNS name ending `.lan` (e.g. `rumi.lan`, set
  `PUBLIC_BASE_URL=http://rumi.lan:8108`) is allowed by the app; not tested yet. Push on a bare IP
  works from app v0.1.4 (the phone only needs ntfy pointed at `http://<LAN_IP>:2586`,
  [PUSH.md](PUSH.md#lan-mode-school-server-on-the-school-wi-fi-no-domain)).
- **Calls from the phone app need HTTPS** (the in-app call screen blocks every plain-http address
  but localhost). So does the **web app on other computers** (it says "Rumi does not support this
  browser"). For those, use a real domain ([section 4](#4-go-live-on-a-real-domain)).

## 8. Calls

`setup.sh` starts everything calls need by default: coturn (the web app's legacy 1:1 calls) and
LiveKit + lk-jwt-service (Element Call, the ONLY way the phone app calls). `CALLS=off` in
`deploy/.env` leaves LiveKit out and stops advertising it; then the phone app cannot call at all.
`scripts/calls-check.sh` must pass after every setup, and `scripts/e2e.sh` checks that the call
address Synapse hands out really answers. Ports, the emulator recipe and the proof are in
[CALLING.md](CALLING.md). For calls between different networks to work, a live server also needs these:

- `TURN_EXTERNAL_IP=<your public IP>` in `deploy/.env`, then run `scripts/setup.sh` again.
- UDP 3478 and UDP 49152-65535 open (coturn), plus TCP 7881 and UDP 50100-50200 (LiveKit, with
  `LIVEKIT_MEDIA_BIND_ADDR=0.0.0.0` and `LIVEKIT_NODE_IP=<public IP>`). Many school firewalls
  block UDP. If they do, a call connects but has no sound or picture.
- A real test: two people on two different networks (home Wi-Fi and mobile data) place a call.
  You can't prove this from the server alone. See [RUNBOOK: Calls](RUNBOOK.md#calls-11-audiovideo-issue-1).

`scripts/e2e.sh` checks that the server hands out call credentials, and that coturn answers.

> **Coming:** group calls and screen sharing use LiveKit, under the `calls` profile
> ([CALLING.md](CALLING.md), [#2](https://github.com/Orenda-Project/rumi-messenger/issues/2)).
> They don't work on a default deployment yet: they need the federation listener re-enabled and a
> `wss://` path. CALLING.md lists these as known gaps.

## 9. Backups

```bash
scripts/backup.sh
```

This writes `backups/<timestamp>/` with a Postgres dump, the uploaded media and the server's
signing key. It then **restores the dump into a scratch database to prove it loads**, and keeps
the newest 14 backups (`BACKUP_KEEP_N`). Schedule it nightly with cron or a systemd timer, and
copy `backups/` off the server. See [RUNBOOK: Backups and restore](RUNBOOK.md#backups-and-restore),
which also has the restore steps.

`backup.sh` doesn't cover these. Back them up yourself, somewhere safe and private:

| File | Why |
|---|---|
| `deploy/.env` | All passwords and secrets for this server |
| `deploy/rumi-cross-signing-recovery-key.txt` | Rumi's identity keys ([section 6](#6-connect-rumi)) |
| `deploy/rumi-channel.env` | Rumi's access token |
| rumi-platform's `.env` and `.matrix-storage/` | Rumi's configuration and encryption state |

We have no measured growth figure yet. Check `du -sh deploy/synapse/data/media_store backups`
weekly for the first month, and size the disk from that. Messages are kept forever by default,
and media is never pruned automatically. See
[RUNBOOK: Media retention](RUNBOOK.md#media-retention) and
[FEDERATION-RETENTION.md](FEDERATION-RETENTION.md).

## 10. Upgrades

Every image in `deploy/docker-compose.yml` is pinned to an exact version on purpose.

- **Knowing when to upgrade:** `scripts/check-upstream-releases.sh` runs weekly in this repo's
  GitHub Actions. It opens an issue here, such as
  [#16](https://github.com/Orenda-Project/rumi-messenger/issues/16), whenever Synapse, Element
  Web, Sygnal or coturn has a newer release. Watch this repository to get those issues. If you
  run the script yourself, it needs an authenticated `gh` CLI, and you should set
  `GITHUB_REPOSITORY=<your fork>` so it files issues there.
- **Upgrading:** follow [RUNBOOK: Upgrading pinned images](RUNBOOK.md#upgrading-pinned-images).
  Take a backup, change the tag, run `docker compose pull && docker compose up -d`, then
  `scripts/e2e.sh`.
- **Before and after an Element Web upgrade,** run `scripts/theme-guard.sh <element port>`, for
  example `scripts/theme-guard.sh 8082`. It checks that the Rumi colours still apply. **Pass the
  port**, because its default is 8182, which isn't the stack default.
- **Upgrading this repo:** `git pull`, then `scripts/setup.sh`. It re-renders config and keeps
  your data.

## 11. Security checklist

- [ ] `scripts/prod-check.sh` passes on the live server.
- [ ] `REGISTRATION_MODE=token`, so no one can create an account without you.
- [ ] `BIND_ADDR=127.0.0.1`, so only Caddy (ports 80/443) and coturn face the internet.
- [ ] Federation stays off (the default): this server doesn't talk to other Matrix servers
      ([why](FEDERATION-RETENTION.md)).
- [ ] One school per server ([section 1](#1-what-you-are-setting-up)).
- [ ] `deploy/.env`, `deploy/rumi-channel.env` and the recovery-key file are never committed. They
      are gitignored, so don't force-add them.
- [ ] Backups are copied off the server, and a restore has been tried once
      ([how](RUNBOOK.md#backups-and-restore)).
- [ ] Old admin sessions and stale devices are cleaned up (`scripts/devices.sh list admin`).
- [ ] You're watching this repository for upgrade issues.

Found a vulnerability? Follow [SECURITY.md](../SECURITY.md), not a public issue.

## 12. Day-to-day fixes

| Problem | Fix |
|---|---|
| A teacher's messages fail with "not verified one or more of your devices" | `scripts/devices.sh list +923001112233`, then `scripts/devices.sh prune +923001112233`. This removes unnamed devices that never synced, and asks first. The teacher then retries the message. See [RUNBOOK](RUNBOOK.md#stale-devices-and-why-a-teachers-phone-can-suddenly-stop-sending). |
| A teacher's new phone shows "reset your digital identity" | Tell them not to reset. They should sign in while their old device is open, or use their recovery key ([#14](https://github.com/Orenda-Project/rumi-messenger/issues/14)). |
| Rumi doesn't answer anyone | Check that rumi-platform is running (`rumi status` in its checkout) and look at its log. Then check `scripts/logs.sh -s synapse`. |
| Rumi's replies show a red shield | `scripts/bot-cross-sign.sh` ([section 6](#6-connect-rumi)). |
| A teacher can't find a colleague | The colleague needs an account with a real name (`scripts/teacher.sh add`). Search matches the start of words. |
| Anything else | `scripts/logs.sh` (all services) or `scripts/logs.sh -s synapse`, then [RUNBOOK: Common failures](RUNBOOK.md#common-failures). |

Start and stop: `cd deploy && docker compose up -d` / `docker compose stop`. Data is kept.

**A note on ports in the RUNBOOK:** its examples use `8108` because that's the maintainers' own
test server. Wherever you see `127.0.0.1:8108`, use your `SYNAPSE_PORT` instead (default `8008`).

## 13. Getting help

- Search or open an issue: [github.com/Orenda-Project/rumi-messenger/issues](https://github.com/Orenda-Project/rumi-messenger/issues).
  Include the failing command, its output, and `scripts/e2e.sh` output. Remove passwords and
  tokens first.
- How it works inside: [ARCHITECTURE.md](ARCHITECTURE.md). Every operation in detail:
  [RUNBOOK.md](RUNBOOK.md). Logs: [LOGGING.md](LOGGING.md).
- The Synapse server underneath is documented upstream, in
  [Synapse's own docs](https://element-hq.github.io/synapse/latest/).
