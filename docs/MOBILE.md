# Mobile

Rumi Messenger doesn't ship its own mobile app. Instead, any standard Matrix client works against
your homeserver -- point it at your `PUBLIC_BASE_URL` and it behaves like any other Matrix
account, including a real 1:1 chat with `@rumi`.

## Element X (Android / iOS)

[Element X](https://element.io/app) is the modern rewrite of Element's mobile client, built on
the same Rust SDK this stack's E2EE relies on.

1. Install Element X from the App Store or Google Play.
2. On the sign-in screen, choose **"I already have an account"** -> **"Other"** as the
   homeserver (not one of the quick-pick providers).
3. Enter your server's `PUBLIC_BASE_URL` (e.g. `https://chat.yourschool.org`, or
   `http://192.168.x.x:8108` for a local test on the same network -- a phone can't resolve
   `localhost` to your dev machine).
4. Sign in with the account you registered on Element Web.

A brand-new account still gets the server-side welcome flow -- `#rumi-announcements` auto-join
plus the `@rumi` DM -- because that lives in the homeserver config and rumi-platform's adapter,
not in any particular client.

## FluffyChat (the Flutter alternative)

[FluffyChat](https://fluffychat.im/) is a Flutter-based Matrix client, open source, available on
Android, iOS, and web/desktop. Same connection flow: choose a custom homeserver during login, enter
your `PUBLIC_BASE_URL`. It's worth having as a second option if a school's device fleet already
has a preference, or if Element X's minimum OS version is a blocker on older devices.

## Push notifications

Neither Element X nor FluffyChat can push-notify a phone about a new message without a push
gateway sitting between your homeserver and Apple/Google's push services -- self-hosting Matrix
does not give you this for free. Two paths:

- **Sygnal + your own FCM/APNs keys.** [Sygnal](https://github.com/matrix-org/sygnal) is
  Matrix's own reference push gateway. Point Synapse's `push` config at a Sygnal instance you run,
  and Sygnal at Firebase Cloud Messaging (Android) and Apple Push Notification service (iOS)
  credentials you provision yourself. This is the most control, and the most setup -- an FCM
  project and an Apple Developer account are both prerequisites, and neither is in scope for
  `scripts/setup.sh` today.
- **UnifiedPush.** An alternative, more privacy-respecting push standard some Matrix clients
  (FluffyChat included) support natively, routing through a distributor app instead of Google's
  infrastructure. Simpler on Android (e.g. via [ntfy](https://ntfy.sh/) as a distributor); iOS
  support is thinner.

Without either, both clients still work -- messages just arrive silently until the app is opened
(a background sync, not a push). For a pilot with a handful of teachers checking in during the
day, this is often good enough to start; treat push as a follow-up once you're past evaluation.

## The honest limits

- **No phone-number discovery.** Unlike WhatsApp, there's no "is this contact on Rumi Messenger"
  lookup by phone number -- accounts are Matrix user ids (`@teacher:yourserver.org`), created by
  registration or invited by a token. A teacher can't "just find" another teacher by their phone
  number the way WhatsApp lets them; they need a room, an invite, or a shared alias.
- **Sync-first, not offline-first.** Matrix clients need a working connection to send and receive
  in real time; a message composed offline queues locally and sends on reconnect (client-dependent
  behavior, not a server guarantee), but there's no store-and-forward design tuned for
  intermittent rural connectivity the way some offline-first apps are. For a classroom with
  patchy signal, expect delivery lag, not delivery loss -- Synapse holds every event for a
  disconnected client to catch up on once it's back.
- **No official Rumi-branded mobile app.** Element X and FluffyChat are both general-purpose
  Matrix clients wearing your homeserver's name, not a purpose-built Rumi app. Everything about
  Rumi as a *contact* (the welcome DM, the coaching/reading/lesson-plan features) works identically
  through them, because that logic lives server-side in rumi-platform, not in the client -- but
  the UI is a generic chat app's UI, not a bespoke one.

## What a white-label build would take

A fully white-labeled mobile app (your own icon, your own name, the Play Store/App Store listing
under your org) is possible but is a real second project, not a config flag:

- **Element X** is open source (Apache-2.0/AGPL, [github.com/element-hq/element-x-ios](https://github.com/element-hq/element-x-ios)
  and [element-x-android](https://github.com/element-hq/element-x-android)) and was built with
  white-labeling in mind, but forking, rebranding, and running your own release pipeline (App
  Store/Play Store developer accounts, code signing, CI) is weeks of work, not hours, and you'd
  own keeping the fork current with upstream security fixes.
- **FluffyChat** is also open source (AGPL) and Flutter-based -- a Flutter rebrand is
  comparatively more approachable if you already have Flutter/mobile-release experience in house,
  for the same reasons a Flutter build is generally easier to theme and rebuild than a native
  Swift/Kotlin one.

Neither is built or scripted by this repo. If you get to the point of needing this, treat it as
its own project with its own timeline -- don't block a pilot on it. Element X / FluffyChat pointed
at your server today.
