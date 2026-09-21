# Rumi Messenger -- Build Plan

**Goal.** A self-hosted, end-to-end encrypted messenger that Rumi deployments can use instead of WhatsApp
(Meta starts billing service messages on 1 Oct 2026). Normal teacher-to-teacher chat and groups work like any
messenger; Rumi is present in the app as a first-class contact every new user lands in.

**Why Matrix, not Signal.** Signal's server cannot be self-hosted past registration (contact discovery runs in an
SGX enclave; storage-service, SVR2 and zkgroup params are undocumented). Matrix gives the same shape: a
store-and-forward homeserver that never sees plaintext, keys only on clients, multi-device, open spec, Apache/AGPL.

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

Rumi placement in the app: Element `welcome_user_id: "@rumi:<server>"` opens a DM with Rumi for every new
account, Synapse `auto_join_rooms` puts everyone in `#rumi-announcements`, brand theme (navy + coral, product
expression of rumi-brand), branded welcome page.

## Work packages (built in parallel, each with a separate harsh critic)

| # | Package | Where | Bar the critic compares against |
|---|---|---|---|
| A | Matrix channel driver for rumi-platform | `rumi-platform` branch `feat/matrix-channel` | The Discord driver trio + its tests. `npm test` green, parity test passes, live roundtrip against local Synapse. |
| B | Deploy stack + one-command setup + E2E script + logging | `deploy/`, `scripts/` | Fresh clone -> `scripts/setup.sh` -> `scripts/e2e.sh` passes on a clean machine with only Docker. |
| C | Branded Element Web + Rumi placement | `deploy/element/` | Screenshot vs rumi-brand product tokens; a new user's first screen is a DM with Rumi. |
| D | Docs: README, ARCHITECTURE, RUNBOOK, LOGGING, RUMI-INTEGRATION, MOBILE | `README.md`, `docs/` | rumi-platform's own README/CLAUDE.md quality (same org); every command in the docs actually runs. |

Exit: every critic picks ours over the bar, blind. Round count is not an exit.

## Out of scope for v1 (documented, not built)
Rebuilt Android/iOS apps (Element X / FluffyChat point at this server via config; push gateway needs FCM keys),
phone-number identity server, federation, TLS termination (RUNBOOK covers Caddy), retention tuning at scale.

## Decisions
See `docs/DECISIONS.tsv` (append-only: ts, phase, decision, why, evidence, result).
