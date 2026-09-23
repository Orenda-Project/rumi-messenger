# Federation and Message Retention Decision Brief

> **Status 2026-09-23: IMPLEMENTED as recommended.** Federation OFF (`federation_domain_whitelist: []`
> plus the `federation` listener resource removed, in `scripts/setup.sh`; `scripts/e2e.sh` asserts
> `/_matrix/federation/v1/version` returns 404). Retention left indefinite. Both reversible, see
> [RUNBOOK.md](RUNBOOK.md#federation-and-message-retention-issue-8).

## Current State (as of the brief, before implementation)

**Federation:** Was ENABLED by default in Synapse (no explicit disable in `homeserver.yaml`). The setup script sets `prefer_local_users=true` in `user_directory` config, which accommodates federation awareness but doesn't use it. PLAN.md lists federation as "out of scope for v1".

**Message Retention:** Not configured. Synapse's default behavior is indefinite retention (no auto-deletion of messages).

### Config References
- `deploy/synapse/data/homeserver.yaml` — no `federation_domain_whitelist` or `disable_federation` keys set
- `scripts/setup.sh` Step 3 — message retention not patched into config
- `docs/PLAN.md` — federation listed as out-of-scope for v1

---

## Tradeoff Analysis for School-Messenger Use Case

**Federation (inter-homeserver communication):**
- **Enabled:** Synapse can communicate with other Matrix servers. Lets teachers from different schools chat if those schools run their own Synapse instances. Increases attack surface (routing through the public federation network), moderation complexity (your server is now a relay for external traffic), and storage cost (storing federated account information).
- **Disabled:** This server is an island. Teachers can only chat with other teachers on THIS Synapse. Simpler operations, no external federation traffic, no need to moderate cross-server issues.

**Message Retention (auto-deletion policy):**
- **Enabled (e.g., 90 days):** Saves storage long-term, protects privacy (old conversations disappear), reduces data breach scope (less history to expose). Teachers lose conversation history for class reviews or disputes.
- **Disabled (indefinite):** Keeps all messages forever. Teachers have full chat history for lesson planning, review, or evidence in disputes. Storage cost grows over time; more data at risk in a breach.

---

## Recommendation

### Federation: **Disable (default OFF)**

**Reasoning:** Single-school deployment with no current inter-school comms need. Federation adds complexity and attack surface for zero benefit today. Revisit only when multi-school collaboration becomes a real requirement.

**Config change:**
```yaml
# In homeserver.yaml, add:
federation_domain_whitelist: []  # or omit entirely (default disables)
# OR explicitly in the patching Python (scripts/setup.sh Step 3):
config["federation_domain_whitelist"] = []
```

### Message Retention: **Keep indefinite (current behavior)**

**Reasoning:** Small deployment (one school, ~100–500 teachers). Storage cost is negligible. Teachers benefit from full history for lesson context, dispute resolution, and compliance. Revisit when storage cost becomes measurable (e.g., >1TB or years of heavy use).

**Current state requires no change.** If retention is needed later:
```yaml
# In homeserver.yaml:
retention:
  enabled: true
  default_policy:
    min_lifetime: 86400000      # 1 day minimum (don't delete in first 24h)
    max_lifetime: 7776000000    # 90 days max (auto-delete older)
```

---

## Next Steps

1. **Disable federation** in the next deployment cycle (add the whitelist config to Step 3 of `scripts/setup.sh`).
2. **Monitor Postgres disk usage** in production. If storage exceeds 500GB, revisit retention policy.
3. **Re-evaluate at multi-school milestone** if the team plans to connect two or more school Synapse instances.

