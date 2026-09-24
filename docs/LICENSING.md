# Licensing, trademarks and what a school must know

Rumi Messenger is free to run, for any number of schools, in any country. Nothing here needs a
payment to anyone. This page says exactly which obligations come with that and how this project
meets them. It is a plain-language summary written by the maintainers, not legal advice.

## Do we owe Element anything?

No. [Element's pricing page](https://element.io/en/pricing) sells support and extras: their
**Community** tier is the same open-source Synapse and Element that we run, free of charge; the
**Enterprise** and **Sovereign** tiers add Synapse Pro, single sign-on, audit tooling, an admin
interface and a support contract with an SLA. Element labels the Community tier "not intended for
production", which is a support statement, not a licence restriction. We chose the open-source path
on purpose and replaced the extras we need with other open software (Caddy for TLS, ntfy for push,
LiveKit for calls, this repo's scripts for backups and checks). What we do not have is Element's
support desk: security updates are our job, and `scripts/check-upstream-releases.sh` runs weekly to
flag them.

## The licences we ship under, and what each asks of us

| Component | Licence | Obligation | How we meet it |
|---|---|---|---|
| Synapse, Element Web, Element X Android, Sygnal, lk-jwt-service, Element Call | AGPL-3.0 (Element relicensed from Apache-2.0 in Dec 2023) | If you modify it and run it as a network service or hand it to users, publish your modified source under AGPL-3.0 and keep the notices | Both our forks are public: [Orenda-Project/rumi-messenger](https://github.com/Orenda-Project/rumi-messenger) (configuration, no code changes to Synapse or Element Web) and [Orenda-Project/element-x-android](https://github.com/Orenda-Project/element-x-android) (branch `rumi-brand`, AGPL-3.0, every change visible). **They must stay public.** |
| LiveKit, ntfy, Caddy | Apache-2.0 | Keep copyright and licence notices | Unmodified official images; credited in the README |
| coturn | BSD-3-Clause | Keep notices | Unmodified official image; credited |
| PostgreSQL | PostgreSQL licence | None | Unmodified |
| This repository's own scripts and docs, and Rumi's Matrix channel in rumi-platform | Apache-2.0 | None for users | Our code talks to Synapse over its public API; it is not a derivative of AGPL code |

If a school ever wants to keep private changes to Synapse or the app, the AGPL does not allow that.
Element sells an alternative licence for exactly that case (see their AGPL announcement); we have
not needed it and do not plan to.

## Trademarks: why nothing here is called "Element"

Element's [trademark policy](https://element.io/legal/trademark-policy) requires a fork to
"choose a distinct brand and identity" and not use Element's name or logo in the product's name,
branding or presentation. The open-source licence covers the code, not the trademarks. So:

- The app is **Rumi Messenger**, with the Rumi mark, Rumi colours and its own app id
  (`ai.hellorumi.messenger`). Every visible "Element" string was removed and is checked for.
- We say, in plain text and with credit, that it is built on Element X and Element Web. That is
  allowed. Using Element's logo, or calling it "Rumi Element", is not.
- Keep this in marketing material too: describe it as "built on the open Matrix protocol and
  Element's open-source apps", never as an Element product.

## Scale and geography

No licence limits the number of users, schools or countries. The deployment model is one server per
school or per operator (federation is off by design), which also keeps each school's data on its own
server.

## Things the software cannot decide for you

- **Data protection law.** Schools hold data about children and staff. Self-hosting with end-to-end
  encryption is the strongest technical position, but where the server sits, who the admin is, how
  long messages are kept (see [FEDERATION-RETENTION.md](FEDERATION-RETENTION.md)) and what teachers
  are told are policy decisions under each country's law.
- **Rumi's AI processing.** Whatever terms and consents apply to Rumi on WhatsApp apply here
  identically; the channel changes nothing about what Rumi does with a message.
- **App stores.** Distributing the APK from GitHub Releases carries no store terms. A Play Store
  listing would.
- **Security response.** Without a vendor contract, patching is on the operator. The upstream
  release alert and `scripts/theme-guard.sh` exist to make image bumps routine.
