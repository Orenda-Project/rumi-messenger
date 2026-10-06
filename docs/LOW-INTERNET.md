# Rumi Messenger on low internet

How WhatsApp stays usable on bad networks, what Rumi Messenger (Matrix, Synapse, Element X Android,
LiveKit) does today, and what to build next. Written 2026-10-06 from published sources and a read-only
audit of this repo and the Android fork at v0.1.5-rumi. Nothing here was measured on a phone yet.

Tracking issues: app side [element-x-android#7](https://github.com/Orenda-Project/element-x-android/issues/7),
server side [rumi-messenger#25](https://github.com/Orenda-Project/rumi-messenger/issues/25).

## Summary

Rumi Messenger already does the two things that matter most offline: messages queue on the phone and
send when the network returns, and chats you have opened stay readable. Where it loses to WhatsApp is
cost per byte, media on mobile data, calls on bad networks, and install size. Four of those five are
ours to fix in days, not months.

- **Transport:** a text message costs about 6.5 KB on Matrix against a few hundred bytes on WhatsApp.
  We cannot change the protocol, but gzip and turning presence off cut the idle cost sharply.
- **Media:** compression is comparable, but there is no data-saver or Wi-Fi-only download policy, and
  the low video preset is hidden. A teacher on a 2 GB monthly bundle will feel this first.
- **Calls:** the largest gap. WhatsApp runs speech at 6 kbps through relays on ten-year-old phones;
  ours needs UDP end to end, has no audio-only mode and no TCP relay, and has not been tested across
  two mobile networks.
- **Install:** 118 MB for arm64 and 339 MB for 32-bit phones, against about 60 MB. A one-line
  workflow change publishes the 32-bit build.
- **Structural:** offline search, delivery ticks and a compact transport are Matrix or Element gaps
  with no active upstream work. Plan around them.

First sprint: 32-bit APK, gzip plus presence off plus media retention, data-saver switch, instant
offline banner, voice notes at 16 kbps. Second: calls over TCP and TLS with tuned Opus, on a VPS with UDP.

## Why WhatsApp works on bad internet

WhatsApp treats the phone as the system of record and the server as a short-lived queue, and it spends
engineering on every byte and every lost packet. Meta documents some of this directly; the rest comes
from reverse engineering or measurement and is marked as such.

| Technique | What WhatsApp does | Source |
| --- | --- | --- |
| One persistent encrypted socket | A single long-lived TCP connection with Noise Pipes (Curve25519, AES-GCM). Resume after a drop is one round trip because the server key is already known. | Primary: [security whitepaper](https://www.bitsoffreedom.nl/wp-content/uploads/WhatsApp-Security-Whitepaper.pdf) |
| Binary protocol with a token dictionary | XMPP-shaped but binary (FunXMPP), single-byte tokens for common strings, 3-byte length prefix per frame. A 36-character text cost about 317 bytes on the wire in a 2014 ISP study. | Secondary: [GetStream](https://getstream.io/blog/whatsapp-works/), [ACM 2014](https://dl.acm.org/doi/pdf/10.1145/2740070.2631461) |
| Server is a 30-day queue, not an archive | Undelivered messages held encrypted up to 30 days, then deleted. Delivered messages are not stored on the server. Full history lives on the phone. | Primary: [privacy policy](https://www.whatsapp.com/legal/privacy-policy), [Meta multi-device](https://engineering.fb.com/2021/07/14/security/whatsapp-multi-device/) |
| Outbox with honest delivery states | Clock icon = queued on the phone. One grey tick = reached the server, two grey = delivered to the device, two blue = read. Correct however long the recipient is offline. | Secondary: [Android Authority](https://www.androidauthority.com/whatsapp-checkmarks-3077273/) |
| Control plane separate from media | A photo is encrypted with a random key and uploaded to a blob store. The chat message carries only key, hash and pointer, so the socket never carries bulk bytes. | Primary: security whitepaper |
| Per-network media policy | Separate auto-download toggles for photos, audio, video, documents on mobile data, Wi-Fi and roaming. Standard versus HD per network, reportedly via the sender uploading two encrypted versions. | Secondary: [Androidayuda](https://en.androidayuda.com/news/applications/New-feature-in-WhatsApp:-how-to-configure-the-quality-of-automatic-file-downloads/) |
| Hard compression before upload | Standard photos about 1600 px long edge, HD up to 4096 px. Gallery video capped near 16 MB. "Send as document" bypasses compression. | Secondary: [MacRumors](https://forums.macrumors.com/threads/whatsapp-gets-hd-photos-option-for-sending-high-res-images.2398991/), [fast.io](https://fast.io/resources/whatsapp-file-size-limit/) |
| Voice notes at about 16 kbps | Opus in Ogg, roughly 16 kbps, 16 kHz mono, measured by users. A one-minute note is about 120 KB. | Secondary: [ThreadRecap](https://www.threadrecap.com/en/blog/bulk-transcription-whatsapp-opus) |
| Calls built for lossy links and old phones | All media through Meta relays that measure loss per leg, feed it back for bandwidth estimation, and retransmit from a packet cache on NACK. The MLow codec gives usable speech at 6 kbps (POLQA 3.9 vs Opus 1.89) and beats Opus at 14 kbps with 30% loss, with 10% less CPU, because tens of millions of daily calls run on phones over ten years old. A "use less data for calls" switch exists. | Primary: [Meta relay talk](https://atscaleconference.com/calling-relay-infrastructure-at-whatsapp-scale/), [Meta MLow](https://engineering.fb.com/2024/06/13/web/mlow-metas-low-bitrate-audio-codec/) |
| Encrypted backup plus bounded device sync | History survives a phone change through an end-to-end encrypted Google Drive or iCloud backup (64-digit key or password in an HSM vault). A new linked device gets a bundle of recent chats from the phone. | Primary: [Meta E2EE backups](https://engineering.fb.com/2021/09/10/security/whatsapp-e2ee-backups/) |

Not published by Meta: keep-alive and backoff timings, whether uploads resume mid-file, exact video
transcode settings, how presence and typing are throttled. Minimum Android is 6.0 from September 2026.

## What Rumi Messenger does today

Sync-first with a good offline cache, not offline-first. The server is the archive and the phone keeps
a bounded copy. Every line was verified in the fork (Element X Android on Matrix Rust SDK 26.09.9) or
in this repo's deploy scripts.

| Area | What it does now | Where |
| --- | --- | --- |
| Transport | HTTPS long-poll with JSON (Simplified Sliding Sync). One text message with connection setup is about 6.5 KB per [Matrix.org](https://matrix.org/blog/2021/06/10/low-bandwidth-matrix-an-implementation-guide/). No persistent socket, no binary framing. Caddy sends responses uncompressed. | `deploy/Caddyfile` |
| Offline sending | Per-room send queue in encrypted SQLite, survives app kill, re-enabled 500 ms after sync resumes. Media uploads queued too. Failed sends show a red mark with Retry or Remove. HTTP retries 3 times with a 30 s timeout. | `appnav/.../SendQueues.kt`, `RustMatrixClientFactory.kt` |
| Offline reading | Event cache persisted by SDK default, so opened chats render offline. Media cache 500 MB, 20 MB per file, 30-day expiry. Older history and search need the server. Nothing in our code configures or tests this. | `RustMatrixClientFactory.kt` |
| Delivery states | Sending, sent, failed, read receipt. No "delivered to phone" tick. | `LocalEventSendState.kt` |
| Server retention | Synapse keeps all messages and media forever; media capped at 50 MB per file, never pruned. | `deploy/synapse/patch_homeserver.py`, RUNBOOK |
| Media send | Images downscaled to about 1280 px at JPEG quality 78, with an 800x600 thumbnail and blurhash. Video always transcoded to H.264 at 1280 px. "Optimise media quality" toggle on by default. A 640 px low preset exists behind a feature flag that is off. Voice notes Opus 24 kbps, 48 kHz. | `mediaupload/.../ImageCompressor.kt`, `VideoCompressorConfig.kt`, `VoiceRecorderBindingContainer.kt` |
| Media receive | Thumbnails load automatically when scrolled into view, full file on tap. No Wi-Fi vs mobile policy, no data saver. Encrypted media must download in full before display. | `TimelineItemImageView.kt`; grep `isMetered`: no hits |
| Offline indicator | Offline banner appears only when the SDK sync gives up, worst case about 90 s. | `DefaultNetworkMonitor.kt`, `RustSyncService.kt` |
| Push | Self-hosted ntfy, no Google FCM. Push carries only an event id, so each notification costs a second fetch. The ntfy app must stay alive with battery optimisation off. | `docs/PUSH.md`, `PushDataUnifiedPush.kt` |
| Calls | Element Call in a WebView on LiveKit. Needs UDP end to end: coturn is plaintext on 3478 with `no-tls` and `no-tcp-relay`, so a TCP-only network gives a connected but silent call. No audio-only or low-data mode. One upstream report of a call dropping at 50% loss ([livekit#4480](https://github.com/livekit/livekit/issues/4480)). Cross-network calls untested. | `deploy/livekit/livekit.yaml`, `scripts/setup.sh`, `docs/CALLING.md` |
| Install size | arm64 APK 117.7 MB, universal 339 MB. No armeabi-v7a APK published, so older budget phones get 339 MB. Minimum Android 7.0. | release v0.1.5-rumi, `rumi-release.yml` |
| Backup and new phone | Server holds history; a new phone needs the recovery key or device verification, otherwise old messages are unreadable. | `RustMatrixClientFactory.kt`, #14 |
| Presence | Enabled on Synapse, which adds sync traffic on every online/offline change. | `patch_homeserver.py` |

Our own changes on the fork are branding, push gateway, a key-sharing strategy and a call header fix.
Nothing we wrote touches compression, caching, sync or network policy.

## Gap table

| Feature | WhatsApp | Rumi Messenger today | Gap | Who can close it |
| --- | --- | --- | --- | --- |
| Bytes per text message | A few hundred bytes over a persistent binary socket | About 6.5 KB with setup, JSON over HTTPS, uncompressed | Large | Partly us: gzip, presence off, lazy members (#22). The transport is Matrix; the low-bandwidth CoAP work (MSC3079) stalled in 2021 |
| Send while offline | Queued, sent on reconnect | Same | None | Verify on a real phone |
| Read recent chats offline | Full history on phone | Opened chats and recent timeline; older history needs the server | Medium | Us: back-pagination and cache sizes (element-x-android#6) |
| Offline search | Works on phone | Not available | Medium | Upstream; no plan found |
| Delivery ticks | Server, delivered, read | Sent, failed, read receipt | Small | Upstream; delivery receipts are not in the Matrix spec |
| Media auto-download policy | Per type, per network; standard vs HD | None | Large on mobile data | Us (element-x-android#2) |
| Media compression | 1600 px standard, HD opt-in | 1280 px q78; 640 px preset hidden | Small | Us (element-x-android#2) |
| Voice notes | About 16 kbps | 24 kbps | Small | Us (element-x-android#4) |
| Media retention on server | Deleted on delivery, 30-day cap | Kept forever | Operational | Us (#23) |
| Offline indicator | Immediate | Up to 90 s | Small | Us (element-x-android#3) |
| Push with app closed | FCM high priority | ntfy, id-only payload, second fetch | Medium | Partly us; id-only payload is by design for encryption |
| Calls on weak or TCP-only networks | Relay, 6 kbps codec, old phones, low-data switch | Needs UDP, no TCP relay, no audio-only, drops at heavy loss, untested cross-network | Largest | Partly us (#24); audio-only mode is upstream Element Call |
| Install size on budget phones | 50 to 70 MB | 118 MB arm64, 339 MB for 32-bit | Large | Us (element-x-android#1) |
| New phone, old history | Encrypted cloud backup | Needs the recovery key | Medium | Us for the UX (element-x-android#5, #14); mechanism is upstream |

## Recommended work order

Impact for teachers against effort. Top-left is a week of work and removes most of the daily pain.

| | Low effort | High effort |
| --- | --- | --- |
| **High impact** | 32-bit APK split · gzip + presence off · 640 px preset on mobile data · instant offline banner · data-saver media switch | TURN over TCP and TLS · Opus bitrate + FEC in LiveKit · audio-only calls (upstream) · binary transport (upstream) |
| **Lower impact** | recovery key first-run · voice notes 16 kbps · media retention on server | bigger offline cache + test · offline search (upstream) |

Every step has a pass test on a real phone on a Pakistani mobile network with Wi-Fi off.

1. **Publish the 32-bit APK and shrink the universal one.** Test: install on a 32-bit phone with 1 GB RAM; app opens and signs in.
2. **Server: gzip at Caddy, presence off, media retention.** Test: capture one idle hour of sync traffic before and after on mobile data; expect well under half the bytes.
3. **Data-saver switch in the app** (always / Wi-Fi only / never for thumbnails), unhide the quality picker, default 640 px video on mobile data. Test: send a 5 MB photo and a 30 s video on mobile data; receiver sees a blurhash and tap-to-download.
4. **Instant offline banner.** Test: airplane mode on; banner within 2 s.
5. **Voice notes at 16 kbps.** Test: a 60 s note near 120 KB and still clear.
6. **Recovery key made unmissable.** Test: reinstall, enter the key, old chats readable.
7. **Calls on hostile networks.** coturn with TCP relay and TLS on 443; LiveKit Opus 16 to 24 kbps with in-band FEC and DTX; a UDP SFU on a VPS, not Railway. Test: voice call between two phones on different mobile networks, then with UDP blocked; both connect with audio.
8. **Bigger offline cache and a real test.** Test: open a 200-message chat, go offline, scroll to the top.
9. **Watch upstream.** Audio-only call mode and loss tolerance live in Element Call; offline search and a compact transport are Matrix-level with no active work. Raise an issue for audio-only with pilot numbers; do not build these ourselves.

## Method and sources

Three investigations on 2026-10-06: a web review of WhatsApp's published engineering, a web review of
Matrix, Synapse, the Rust SDK and LiveKit, and a read-only audit of the fork at v0.1.5-rumi and this
repo's deploy scripts.

Still unverified: whether Element X shows a received blurhash before download; the Rust SDK's reconnect
backoff timing; WhatsApp's keep-alive, backoff and resumable upload behaviour; LiveKit's exact loss
tolerance in Element Call; APK memory use on a 1 GB phone. The most useful next measurement is one idle
hour and one message of sync traffic captured on a phone on mobile data, before and after the server changes.

Primary sources: [WhatsApp security whitepaper](https://www.bitsoffreedom.nl/wp-content/uploads/WhatsApp-Security-Whitepaper.pdf),
[WhatsApp privacy policy](https://www.whatsapp.com/legal/privacy-policy),
[Meta: MLow codec](https://engineering.fb.com/2024/06/13/web/mlow-metas-low-bitrate-audio-codec/),
[Meta: call relay infrastructure](https://atscaleconference.com/calling-relay-infrastructure-at-whatsapp-scale/),
[Meta: multi-device](https://engineering.fb.com/2021/07/14/security/whatsapp-multi-device/),
[Meta: encrypted backups](https://engineering.fb.com/2021/09/10/security/whatsapp-e2ee-backups/),
[MSC4186 Simplified Sliding Sync](https://github.com/matrix-org/matrix-spec-proposals/blob/erikj/sss/proposals/4186-simplified-sliding-sync.md),
[Rust SDK send queue](https://docs.rs/matrix-sdk/latest/matrix_sdk/send_queue/index.html),
[Rust SDK event cache](https://docs.rs/matrix-sdk/latest/matrix_sdk/event_cache/index.html),
[Matrix low-bandwidth guide](https://matrix.org/blog/2021/06/10/low-bandwidth-matrix-an-implementation-guide/),
[Synapse configuration](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html),
[LiveKit media docs](https://docs.livekit.io/transport/media/advanced/),
[LiveKit ports](https://docs.livekit.io/transport/self-hosting/ports-firewall/),
[Element X image compression](https://github.com/element-hq/element-meta/issues/2543).
