# Contributing to Rumi Messenger

Thanks for wanting to help. This repo is small on purpose -- a deploy stack, a handful of
scripts, and docs -- so most contributions fall into one of three buckets: fixing the deploy
stack, improving the docs, or extending the Matrix side of the integration (which mostly lives
in `rumi-platform`, not here).

## Getting started

1. Fork the repository.
2. Clone your fork: `git clone https://github.com/YOUR-USERNAME/rumi-messenger.git`
3. Create a branch: `git checkout -b fix/your-change`
4. Run `scripts/setup.sh` and `scripts/e2e.sh` to get a working stack before you change anything --
   that's your baseline.
5. Make your change.
6. Re-run `scripts/e2e.sh`. It must still pass 10/10.
7. Push and open a Pull Request.

## What lives where

- `deploy/` -- the Docker Compose stack (Postgres, Synapse, Element Web, optional Caddy).
- `scripts/` -- `setup.sh` (one-command bring-up), `e2e.sh` (verification), `logs.sh`,
  `backup.sh`, `reset.sh`, `connect-rumi.sh`.
- `docs/` -- architecture, day-2 operations, logging, mobile clients, and the rumi-platform
  integration guide.
- `docs/PLAN.md` and `docs/DECISIONS.tsv` -- the build plan and an append-only decision log.
  Add a row to `DECISIONS.tsv` for any decision worth explaining later; don't rewrite history in
  it.

## Ground rules

- **Every command in a doc must actually run.** If you change a script's flags, output, or
  defaults, update the docs that quote it in the same PR -- and run the command yourself before
  you claim it works.
- **No claim without a check.** Don't write "this fixes X" without having reproduced X and then
  watched it stop happening.
- **Secrets stay out of git.** `deploy/.env`, `deploy/rumi-channel.env`, and anything under
  `deploy/synapse/data/` are gitignored for a reason -- never force-add them, and never paste a
  token into an issue, PR description, or commit message.
- **Idempotency matters.** `scripts/setup.sh` must be safe to re-run. If your change adds a step,
  make sure a second run skips it instead of erroring or regenerating secrets.
- **Pin, don't float.** Image tags in `deploy/docker-compose.yml` are pinned to a specific
  version with an upgrade comment. Don't switch anything back to `:latest`.

## Code style

- Bash scripts: `set -euo pipefail`, a usage comment at the top, and clear `log()`-style output --
  match the existing scripts in `scripts/`.
- Docs: plain language, second person for instructions, and a command block a reader can copy
  and paste without editing (real defaults, not `<placeholder>` where a real value would work).

## Reporting a bug or proposing a feature

Use the issue templates under `.github/ISSUE_TEMPLATE/`. For security issues, see
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## Pull request checklist

- [ ] `scripts/e2e.sh` passes against a stack built by your changed `scripts/setup.sh`
- [ ] No secrets, tokens, or real domains committed
- [ ] Docs updated for any command, port, env var, or file you changed
- [ ] `docs/DECISIONS.tsv` has a row if you made a decision worth remembering
- [ ] Image tags stay pinned (no `:latest`)
