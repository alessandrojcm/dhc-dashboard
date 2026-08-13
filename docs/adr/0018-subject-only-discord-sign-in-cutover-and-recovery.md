# ADR 0018: Subject-only Discord sign-in cutover and recovery

**Status:** Accepted  
**Date:** 2026-08-13  
**Amends:** ADR-0009, ADR-0014, ADR-0016, ADR-0017  
**Tags:** authentication, discord, migration, recovery, operations

## Context

The current Discord callback first resolves an External Identity by Discord
provider subject and, when none exists, reconciles a verified Discord email to
a Principal and creates a link. That fallback was a migration convenience. It
is not an account-ownership proof for a DHC Principal and must not coexist with
the reviewed Staged Discord Assignment model in ADR-0016: a provider-reported
email can be changed, reused, absent, or shared and would bypass the review
gate.

ADR-0014 makes Invitation Acceptance create a verified Discord External
Identity atomically with the new Principal. ADR-0016 makes first use of an
approved Staged Discord Assignment create one for an existing Member. ADR-0017
defines the durable rows and cross-table locking needed by both paths. This ADR
defines the operational cutover from email reconciliation to those
subject-only paths, including its failure and recovery boundaries.

## Decision

### Binding and login rule

After the cutover is committed, the normalized Discord OAuth `sub` is the only
fact that selects a Principal or authorizes creation of a Discord External
Identity. Discord email (verified or otherwise), username, global name, guild
nickname, avatar, browser-supplied Principal ID, and a support assertion are
never lookup, reconciliation, authorization, collision-resolution, or recovery
facts.

Ordinary magic-link login remains an independent login method throughout this
transition. It remains available for a Member with no Discord identity, an
unmapped guild member, an inactive Member whose access is later restored, a
Discord outage, and every recovery flow that needs proof of the destination
Principal. It does not create, repair, or infer a Discord External Identity.

Every successful Discord path passes through ADR-0011's ordinary atomic session
establishment. A subject proof can update allowlisted current metadata on an
existing External Identity, but cannot change its subject, Principal, or the
Principal email.

### Sign-in decision tables

The callback validates OAuth state, PKCE, issuer/client configuration, and a
non-empty normalized `sub` before applying this table. Each identity-affecting
row takes the ADR-0017 subject/principal locks and rechecks its constraints in
the same transaction. Public responses are intentionally non-enumerating.

#### Existing External Identity takes precedence

| Exact `(discord, sub)` External Identity | Member has club access | Result |
| --- | --- | --- |
| One matching identity | Yes | Refresh allowlisted metadata, then establish an ordinary Session. |
| One matching identity | No | Refreshing metadata is optional and must not affect access; establish no Session. Return the ordinary support-safe access-unavailable outcome. |
| No matching identity | N/A | Continue only to the approved-assignment table below. Do **not** inspect any email or name claim. |
| More than one matching identity or other invariant failure | N/A | Fail closed, emit a security/invariant alert, and establish no Session or link. This is an operator incident, not a browser-visible explanation. |

An existing External Identity always wins over an Assignment lookup. A duplicate
callback after a successful promotion consequently follows this table.

#### No External Identity: approved Staged Discord Assignment promotion

| Exact assignment/claim state for `(discord, sub)` | Target Member has club access | Result |
| --- | --- | --- |
| Exactly one `approved` Assignment; no active Subject Claim or competing identity | Yes | Atomically mark the Assignment `promoted`, append its audit event, insert the External Identity, then establish an ordinary Session. |
| Exactly one `approved` Assignment; no active Subject Claim or competing identity | No | Atomically promote and audit the External Identity, but establish no Session. This preserves the reviewed proof without granting access; a later active period requires a fresh sign-in. |
| `approved` Assignment plus an active Subject Claim | N/A | Create no link and no Session. Return the neutral verification-in-progress outcome; alert only if claim age exceeds its continuation fence. |
| `proposed`, rejected, withdrawn, or superseded Assignment | N/A | Create no link and no Session. Return the neutral unable-to-sign-in outcome. |
| No Assignment (including an unmapped guild member) | N/A | Create no link and no Session. Return the same neutral unable-to-sign-in outcome and offer magic-link sign-in and club support. |
| Any duplicate/competing Assignment or External Identity detected by constraints | N/A | Roll back promotion, create no Session, and record a keyed-subject security incident. Do not expose the target Member or collision reason. |

The promotion path is enabled only after the activation gate below. Before then,
an approved Assignment remains reviewed data, not login authority. An inactive
Member is deliberately eligible for promotion: access state controls Session
creation, not preservation of a reviewed identity proof.

#### New Members and active Invitation-Acceptance Subject Claims

| Context | Result |
| --- | --- |
| Invitation Acceptance with a verified Continuation and its own active Subject Claim | Continue only through ADR-0014 finalization: atomically create the Principal, Member, Membership, Role, External Identity, consume/zeroize the Continuation, and delete the claim. Never create a Session. |
| Invitation Acceptance OAuth callback finds a permanent identity, active Assignment, or another active claim for the subject | Terminal collision: create no Stripe work or new Principal, zeroize/release the Continuation as ADR-0014 requires, and return the neutral invitation-specific support outcome. |
| Ordinary Discord sign-in finds an active Subject Claim | It must not promote, create, or reassign a link. Return verification-in-progress without revealing that an invitation or another person is involved. |
| A new acceptance has no verified Continuation/claim | It may not use ordinary sign-in, Discord email, or a staged assignment as a substitute. Restart the invitation-specific verification flow. |

### Gates and rollout

The rollout is an audited state machine, not a collection of independently
flipped browser flags. The authorization service records actor, timestamp,
release revision, reason, and before/after values for every gate transition.
Production reads a transaction-consistent gate snapshot at command start; an
OAuth callback never changes policy halfway through a transaction.

| Gate/state | Enables | Required evidence before transition |
| --- | --- | --- |
| `prepared` | ADR-0017 schema, constraints, locks, audits, metrics, and code paths deployed dark; approved Assignments may be staged and reviewed but cannot promote. Legacy callback remains temporarily available. | Expand migration rehearsal; passing transaction/lock/replay tests; zero cross-table invariant violations; validated dashboards and on-call runbook; signed capture/review receipts and conflict/omission report. |
| `cutover_ready` | A release that can serve every callback without email reconciliation, can require the Invitation Continuation, and can pause Discord safely. | Production-like callback rehearsal; rollback rehearsal; magic-link delivery/recovery smoke test; no unresolved active-assignment conflicts; an authorized operator and two recovery approvers on call. |
| `subject_only_active` (irreversible policy transition) | The legacy verified-email reconciliation branch is disabled; exact-subject External Identity resolution and approved-Assignment promotion are enabled together; all new Invitation Acceptances require ADR-0014 verification. | Change approval during a staffed window, healthy provider and database checks, gate snapshot recorded, and `cutover_ready` evidence still current. |
| `discord_sign_in_paused` (reversible safety brake) | Stops initiating/completing ordinary Discord sign-in and new Assignment promotion while preserving identities, claims, assignments, and magic-link login. Invitation Acceptance is also paused before Discord OAuth/Stripe progression, rather than bypassing Discord proof. | Incident or provider-outage record, operator approval, and public-status/support message. |
| `contracted` | Removes unreachable email-reconciliation code and Discord `email` scope after the observation gate. | The removal criteria below and a tested release that has no email fallback path. |

`subject_only_active` is rollback-safe precisely because it is not reversible:
once any callback has been evaluated under it, no rollback may restore the
email-based linker or deploy a release that contains an active email fallback.
Pre-cutover, the team may return to `prepared` and leave all new durable rows
and constraints in place. Post-cutover, a bad release is rolled forward to a
compatible subject-only release or paused with `discord_sign_in_paused`; it is
never rolled back to a callback that can link by email. Existing External
Identities, promoted Assignments, Continuations, claims, and immutable audits
are never deleted to make a rollback appear clean.

### Observation and email-fallback removal

The cutover dashboard and alerts record only outcome code, gate revision,
release revision, provider status, Assignment/Continuation state, and keyed
subject fingerprints where correlation is necessary. They do not log raw
Discord emails, usernames, OAuth tokens, callback query values, or Member
emails.

At minimum, observe per release and gate revision:

- OAuth start/callback success, cancellation, protocol failure, provider
  failure, latency, and pause outcomes;
- exact External Identity sign-ins, Assignment promotion attempts/successes,
  unmapped outcomes, inactive-access outcomes, active-claim deferrals, and
  constraint/transaction rollbacks;
- Invitation Continuations and claims by lifecycle state and age, collision
  outcomes before Stripe, and finalization/reconciliation outcomes;
- magic-link request, delivery, consumption, inactive-access, and recovery
  success rates; and
- invariant scans: orphan/expired claims, live Continuations without their
  claim, active Assignment/permanent-link overlap, promotion without an audit
  event, and any attempted email-reconciliation branch.

Alert immediately on an invariant violation, a uniqueness/trigger rejection
outside a deliberate race test, an orphaned claim, a promotion missing its audit
event, a material provider-error increase, or any email-link attempt after
activation. Alert thresholds for unmapped and inactive outcomes are baselined
during the staffed observation window; they prompt support capacity review, not
automatic linking.

The email fallback and Discord `email` OAuth scope may be removed only after:

1. `subject_only_active` has operated for at least 14 consecutive days and one
   full normal membership/invitation operating cycle;
2. there are zero unreconciled cross-table invariant alerts, orphan claims,
   unexpected promotion conflicts, or unresolved security incidents in that
   period;
3. all known legacy email-fallback outcomes have an explicit disposition
   (already linked by subject, approved staged mapping, intentionally
   magic-link-only, or recovery case), without creating links from that list;
4. a provider-outage drill proves that magic-link login and the pause gate are
   usable without Discord; and
5. a code search, callback test, and release review confirm no runtime path
   consumes Discord email or `email_verified` for identity selection. Retaining
   a provider-reported email only as ADR-0017 allowlisted display metadata is
   not such a path.

Scope removal is a privacy reduction, not an identity migration. Failure to
receive an email after scope removal cannot affect any outcome.

### Provider outage and support-safe outcomes

Discord OAuth transport/provider failure, invalid state, rejected consent,
missing subject, or the pause gate establishes no Session and makes no binding
change. The public response says that Discord sign-in is temporarily unavailable
or cannot complete, as applicable, and offers magic-link sign-in and club
support. It does not say whether the Discord account, a Member, an Assignment,
or a claim exists.

Support may tell a person how to use magic link, capture a recovery case, and
report an outage. Support cannot query a Discord email/name to identify a
Principal, reveal whether a subject is linked, manually insert an External
Identity, remove a claim, or ask an operator to retry an email fallback.

### Correction, replacement, and recovery

Before first use, a wrong administrator mapping follows ADR-0016 exactly:
withdraw or supersede the immutable proposal, create a fresh proposal from a
new or still-valid controlled capture, and obtain independent review. Neither a
current Discord name nor an email is a correction input.

After promotion, a wrong assignment or a Member-requested Discord account
replacement is a **Discord Identity Recovery** case, never a roster-task edit
or self-service relink. Opening the case immediately disables the affected
Discord sign-in binding and revokes the affected Principal's Sessions. It
records a case ID, reason code, reporter, affected binding fingerprint,
authorizing administrators, evidence references, and every state transition in
immutable audit history; it does not copy raw OAuth evidence or roster data into
general logs.

The recovery command requires all of the following before it can atomically end
or disable the old live binding and create the replacement/transfer binding:

1. fresh OAuth proof of control of the exact incoming Discord subject;
2. fresh magic-link proof of control of the destination DHC Principal (or a
   separately approved equivalent recovery proof);
3. two distinct authorized administrators approving the case, neither relying
   solely on a support request; and
4. no active Subject Claim, active Assignment, or competing External Identity
   for either side, verified under ADR-0017 locks and constraints.

The transaction writes binding history and evidence references, appends the
case audit event, and revokes Sessions for both affected Principals. The
destination must sign in again; recovery never mints a Session. An operator
cannot transfer a subject using a guild roster entry, username, Discord email,
or Member email. A failed proof or collision leaves the existing live binding
unchanged (or, if the case was opened, safely disabled) and remains a recovery
case for resolution.

## Consequences

- Discord login moves from an email-assisted migration shortcut to a strict
  proof-and-subject model without removing magic-link access.
- Unmapped people fail closed but retain a supported route; their friction is
  visible operationally rather than silently converted into account takeover
  risk.
- The one-way policy cutover prevents an emergency rollback from reintroducing
  an unsafe linker after reviewed or invitation-bound identities exist.
- Account replacement is deliberately slower and dual-controlled because it
  transfers a login credential rather than correcting ordinary profile data.

## Considered options

- **Keep verified-email reconciliation for unmapped Members.** Rejected: it
  bypasses the reviewed-assignment and OAuth-proof model and makes mutable
  provider email an authorization fact.
- **Auto-create an Assignment when an unmapped guild member signs in.**
  Rejected: it replaces independent human review with a browser attempt and
  enables enumeration pressure.
- **Temporarily turn email fallback back on during an incident.** Rejected: the
  safe incident response is to pause Discord and use magic link, not to weaken
  account binding.
- **Let an administrator replace a used Discord identity from the roster tool.**
  Rejected: post-use replacement needs proof of both the incoming Discord
  account and destination Principal, so it is credential recovery.
