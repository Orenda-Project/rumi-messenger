# Identity Model — How Teachers Register and Log In

## Overview

Rumi Messenger uses **phone numbers as the login identity** (Matrix username), provisioned by an administrator rather than through self-serve signup. This is a hybrid of two approaches: the login experience mirrors **(A) self-serve SMS signup** — a teacher types a number, not a username — but provisioning is **(B) admin-driven** — no SMS provider, no self-serve flow.

## What Was Built

A teacher's identity is created via admin action:

```bash
scripts/teacher.sh add "+923001234567" "Ayesha Khan"
```

- **Login identity:** Phone number in E.164 format (`+923001234567`), used verbatim as the Matrix username
- **No SMS verification:** The admin types the phone number and teacher's name directly; no one-time code, no SMS provider needed
- **No self-serve signup:** Teachers cannot register themselves; an admin must create every account
- **Directory discoverability:** Teachers can search for colleagues by name via the user directory, not by phone number (search is text-prefix based, searches the `display_name` field, e.g., typing "Ayesha" finds "Ayesha Khan")
- **Private DMs:** To start a direct message with a colleague, a teacher either:
  1. Knows their phone number and types it into the "Start a chat" UI (unlikely for most), or
  2. Searches for them by name in the user directory and taps their profile

## Why This Design

### For a small, single-school deployment (current state):

**Self-serve SMS (option A) was NOT built because:**
- It requires an SMS provider (real per-message cost in Pakistan, needs a commercial decision on which vendor)
- A single school with an admin who already knows every teacher's phone number doesn't need self-serve
- SMS-based verification adds infrastructure complexity for no gain when provisioning is already admin-driven

**Admin-driven phone provisioning (option B, what we built) provides:**
- No vendor lock-in on an SMS provider
- No per-message cost
- Exactly what a school admin does today: "I have the staff list; let me create their accounts"
- Simple, durable, offline-capable (no external API call for every registration)

### For multi-school deployments (future):

If Rumi is deployed across many schools without a central admin, the calculus changes:
- **Option A (self-serve SMS) becomes necessary:** Each teacher can onboard themselves
- **Option B alone becomes insufficient:** A school with 500 teachers cannot hand-type each one

At that point, revisit this decision. The phone-number-as-login identity choice is durable (it's just a username format) — only the provisioning mechanism needs to change.

## Privacy Position

- **No address-book upload:** The system never asks for a teacher's contacts. This repo has no contact-discovery feature.
- **No cross-school isolation yet:** With `search_all_users: true` in Synapse config, every teacher on this homeserver can search and message every other teacher by name. This is fine for one school per homeserver (the current deployment). If multiple schools share one homeserver, this behavior becomes a privacy issue — solve it then (see [RUNBOOK.md's "Privacy" section](./RUNBOOK.md#privacy) for the trade-offs).

## Related Issues & Decisions

- **Issue #10 (user directory search):** Teachers find colleagues by name via Synapse's built-in user directory, not an address book upload.
- **DECISIONS.tsv row 55 (phone as routing identity):** Phone number as the Matrix username was chosen to fit within database column constraints; matrix:@kamal:localhost is 23 chars and was rejected.

## Implementation Anchor

- **Teacher creation:** [`scripts/teacher.sh`](../scripts/teacher.sh)
- **Config:** the generated `deploy/synapse/data/homeserver.yaml` (rendered by `scripts/setup.sh`, not checked into git) — `user_directory` settings
- **E2E verification:** [`scripts/e2e.sh`](../scripts/e2e.sh) — search checks
- **Operations guide:** [RUNBOOK.md's "Teacher directory search" section](./RUNBOOK.md#teacher-directory-search-start-chat-finds-a-colleague-by-name)
