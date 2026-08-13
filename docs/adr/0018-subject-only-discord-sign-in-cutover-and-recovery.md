# ADR 0018: Subject-only Discord sign-in cutover and recovery

**Status:** Accepted  
**Date:** 2026-08-13  
**Amends:** ADR-0009, ADR-0014, ADR-0016, ADR-0017  
**Tags:** authentication, discord, migration, recovery, operations

## Context

The legacy Discord callback can reconcile a verified Discord email to a
Principal when an External Identity is absent. That was a migration shortcut,
not proof that the controller of the Discord account owns the DHC Principal.
It conflicts with ADR-0014's invitation proof, ADR-0016's independently
reviewed existing-Member prefill, and ADR-0017's one-subject binding model.

## Decision

### Binding and sign-in rule

After cutover, normalized Discord OAuth `sub` is the only fact that selects a
Principal or permits creation of a Discord External Identity. Discord email
(verified or otherwise), username, global name, guild nickname, avatar,
browser-supplied Principal ID, and support assertions are never identity
lookup, reconciliation, authorization, collision-resolution, or recovery
facts. Magic-link login remains independent and available throughout; it never
creates or repairs a Discord binding.

Every identity-affecting route uses ADR-0017's subject/principal locks and
constraints, and every successful sign-in invokes ADR-0011's ordinary atomic
session establishment. A callback may refresh allowlisted current metadata on
an existing External Identity but never its subject, Principal, or Principal
email.

| Callback condition | Required result |
| --- | --- |
| Exact External Identity; Member has access | Refresh safe metadata and establish a Session. |
| Exact External Identity; Member lacks access | Establish no Session; return the ordinary support-safe access-unavailable outcome. |
| No identity; exactly one approved Staged Assignment; no claim/conflict | Atomically promote and audit the Assignment, create the External Identity, then establish a Session only when the Member has access. |
| Approved Assignment; Member lacks access | Promote and audit the proved identity but establish no Session; a later login must be fresh. |
| Active Discord Subject Claim | Create no binding or Session; return neutral verification-in-progress. |
| Proposed, terminal, missing, or ambiguous Assignment | Create no binding or Session; return the neutral unable-to-sign-in outcome and offer magic link/support. |
| Invitation Acceptance Continuation/claim | Use ADR-0014 finalization only; never ordinary sign-in, Assignment promotion, or Session creation. |
| Any constraint/invariant failure | Fail closed, alert operators with a keyed fingerprint, and disclose no identity details. |

Existing External Identity resolution always precedes Assignment lookup. The
ordinary callback never inspects an email or name claim after it finds no
identity.

### Gates and release policy

The authorization service records actor, timestamp, release revision, reason,
and before/after values for each gate transition. Commands read one
transaction-consistent snapshot; a callback never changes policy mid-command.

| Gate | Enables | Required evidence |
| --- | --- | --- |
| `prepared` | Dark schema, locks, audits, metrics, and reviewed Assignment staging; no promotion. | Migration and lock rehearsal, zero invariant violations, dashboards/runbook, signed capture/review receipts. |
| `cutover_ready` | A release able to serve every callback without email reconciliation and safely pause Discord. | Callback/rollback rehearsal, magic-link smoke test, no unresolved Assignment conflicts, authorized on-call recovery approvers. |
| `subject_only_active` | Subject-only External Identity sign-in, approved Assignment promotion, and required ADR-0014 acceptance continuation. | Staffed change approval and healthy provider/database checks. |
| `discord_sign_in_paused` | Stops ordinary Discord OAuth completion/promotion and pauses Acceptance before OAuth or Stripe, while magic link remains available. | Incident/outage record and operator approval. |
| `contracted` | Removes email-link code and the Discord `email` scope. | Observation criteria below and a release review proving no runtime email-selection path. |

`subject_only_active` is a one-way policy transition. After it is evaluated by
any callback, do not re-enable the email linker. A bad post-cutover release is
rolled forward to a compatible subject-only release or paused; identities,
claims, Assignments, and immutable audits are never deleted or down-migrated to
make a rollback appear clean.

### Observation, privacy, and recovery

Log and meter outcome code, gate/release revision, provider state,
Continuation/Assignment state, and a keyed subject fingerprint only when
correlation is needed. Never log OAuth query values or tokens, raw Discord
email, username, Member email, or subject. Alert on invariant/trigger
rejections, orphan claims, promotion without an audit event, provider failures,
and any attempted email-link after activation. Baseline unmapped and inactive
outcomes during the staffed observation window; they create support work, not
automatic linking.

Remove the email fallback and `email` scope only after at least 14 consecutive
healthy days and one normal invitation/membership cycle, zero unreconciled
security/invariant incidents, an explicit non-linking disposition for every
legacy fallback outcome, a tested outage/pause drill, and code/test/release
review proving no identity selection reads `email` or `email_verified`.
Retaining a provider email as allowlisted display metadata is not selection.

Before first use, correct a wrong Assignment by withdrawal/supersession, a new
proposal, and independent review. After promotion or for account replacement,
open a dedicated Discord Identity Recovery case: immediately disable the
affected Discord binding and revoke affected Sessions; preserve immutable case
and binding history. Transfer or replacement requires fresh OAuth proof of the
incoming subject, fresh magic-link (or separately approved equivalent) proof of
the destination Principal, approval by two distinct authorized administrators,
and no claim, active Assignment, or competing identity under ADR-0017 locks.
The atomic recovery records evidence references/history and revokes both
Principals' Sessions; it never mints a Session. Names, roster entries, and
emails cannot substitute for either proof.

## Consequences

- Discord login becomes a strict proof-and-subject path while magic link remains
  the safe fallback for outages, unmapped Members, and recovery.
- Unmapped identities fail closed and non-enumerating; support can guide magic
  link or start recovery but cannot manually bind an identity or remove a claim.
- Guild presence is not login ownership and is not synchronized after prefill.

## Alternatives considered

- **Keep verified-email reconciliation.** Rejected because it bypasses reviewed
  or invitation-bound proof.
- **Re-enable email linking during an incident.** Rejected because pause plus
  magic link is the safe incident response.
- **Let roster tooling repair a promoted binding.** Rejected because a used
  identity is a credential-recovery, not data-import, operation.
