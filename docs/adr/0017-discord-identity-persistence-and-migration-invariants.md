# ADR 0017: Discord identity persistence and migration invariants

**Status:** Accepted  
**Date:** 2026-08-13  
**Amends:** ADR-0014, ADR-0016  
**Tags:** authentication, discord, onboarding, migration, data-integrity

## Context

ADR-0014 requires a prospective Member to prove a Discord account before the
Invitation Acceptance payment progression and reserves that verified subject
until atomic conversion. ADR-0016 requires a separately reviewed, pending
mapping for an existing Member, which becomes a login identity only after the
first matching OAuth proof. Both paths can touch the same Discord User ID and
the existing `external_identities` table independently enforces only permanent
links. The target persistence model must therefore prevent a prospective
acceptance, a staged assignment, and a permanent link from racing each other.

This ADR is the persistence and deployment contract for ALE-208 and ALE-209.
It decides durable state, not controller routes, roster tooling, recovery UI,
or OAuth protocol handling.

## Decision

### Binding facts and metadata ownership

Discord's normalized OAuth `sub` is stored verbatim as the non-empty text
**provider subject**. It is the sole binding key. `provider` is constrained to
`'discord'` in every Discord-specific table. A username, global display name,
guild nickname, avatar, Discord email, and `email_verified` are mutable
metadata: none participates in lookup, uniqueness, authorization, or a
recovery decision.

`external_identities` is the one enduring live binding store. Its existing
`metadata` JSONB owns the latest provider profile observed on a successful
OAuth callback. An OAuth login may replace only that metadata object for the
same immutable `(provider, provider_subject, principal_id)` binding; it never
changes `provider_subject`, `principal_id`, or `principals.email`. The
metadata payload is an allowlist of `username`, `global_name`, `avatar`, and
the provider-reported `email`/`email_verified` when received. It is not an
audit record and must not retain an unbounded history of profile values.

`username_snapshot` belongs to a Staged Discord Assignment as immutable review
evidence. It is exactly the roster `user.username` captured for that selected
User ID, and is never refreshed from OAuth or used to reconcile a subject.
The Continuation has an ephemeral `display_metadata` JSONB allowlist solely to
carry the successful OAuth result to finalization. These are three different
ownership roles: current presentation (`external_identities`), historical
human review evidence (assignment), and short-lived workflow input
(Continuation).

### Durable tables

All timestamps below are `timestamptz` and use the repository's
`created_at`/`updated_at` convention. IDs are UUIDs. `reason_code` values are
controlled application enums, not free-text provider responses.

#### `invitation_acceptance_discord_continuations`

This is ADR-0014's invitation-bound continuation, not an External Identity.

| Column | Contract |
| --- | --- |
| `id` | Opaque UUID delivered only through the protected browser session. |
| `invitation_id` | `NOT NULL` FK to `invitations`, `ON DELETE RESTRICT`. |
| `attempt_id` | `NOT NULL` FK to `invitation_acceptance_attempts`, `ON DELETE RESTRICT`. |
| `state` | `awaiting_oauth`, `verified`, `consumed`, `expired`, `cancelled`, `failed`, or `collision`. |
| `provider_subject` | Nullable non-empty text; required in `verified`, and absent before OAuth completes and in terminal/consumed states. |
| `subject_fingerprint` | Nullable before a subject is observed; `NOT NULL` keyed HMAC fingerprint from `verified` onward, never a reversible hash. |
| `display_metadata` | Nullable JSONB allowlist, present only in `verified`; never includes an OAuth token. |
| `expires_at`, `verified_at`, `consumed_at`, `terminal_at`, `reason_code` | Lifecycle fences and support-safe outcome. |

The Invitation/Attempt relationship is checked by a constraint trigger: the
Attempt must belong to the same Invitation. A partial unique index permits at
most one live continuation per Attempt:

```sql
CREATE UNIQUE INDEX invitation_acceptance_discord_continuations_live_attempt
  ON invitation_acceptance_discord_continuations (attempt_id)
  WHERE state IN ('awaiting_oauth', 'verified');
```

The state check also requires `verified_at`, fingerprint, and raw
subject/display metadata in `verified`; requires `consumed_at` and fingerprint
in `consumed`; and requires a terminal time and reason for `expired`,
`cancelled`, `failed`, and `collision` (plus a fingerprint for `collision`). The
application transaction explicitly sets raw subject and display metadata to
`NULL` when transitioning to `consumed` or another terminal state; a deferred
constraint trigger rejects a terminal row which still has either value.

#### `discord_subject_claims`

A claim is ADR-0014's transient reservation, and is deliberately not a
pending External Identity. It has `id`, `continuation_id NOT NULL UNIQUE` (FK
to the Continuation, `ON DELETE RESTRICT`), `provider`, `provider_subject`,
and `created_at`. It has no `principal_id`, profile metadata, token, or
history state.

`UNIQUE (provider, provider_subject)` is the active-claim barrier. Claims are
inserted only when a Continuation becomes `verified`; they are deleted in the
same transaction that either terminalizes the continuation or inserts its
External Identity. Deletion, rather than a released state, prevents a second
raw-subject store after the continuation is zeroized. The continuation's keyed
fingerprint supplies the retained audit correlation.

#### `discord_roster_preflight_executions`

This durable operational receipt makes ADR-0016's required ALE-210 proof a
foreign-keyed fact rather than an opaque log reference. It has `id`, `state`
(`succeeded` or `failed`), `guild_id`, `bot_application_id`, `tool_revision`,
`executed_by_principal_id` (restricting FK to `principals`), `executed_at`,
`evidence_digest`, `reason_code`, and `created_at`. A succeeded row requires
all positive endpoint evidence and no failure reason; a failed row requires a
reason. It retains no token, sampled User object, or roster page. A Capture can
reference only a succeeded row, enforced by a deferred constraint trigger.

#### `discord_roster_captures`

This restricted receipt supports an Assignment without persisting a guild
roster. It has `id`, `preflight_execution_id`, `guild_id`, `bot_application_id`,
`tool_revision`, `capture_digest`, `roster_count`, `captured_by_principal_id`,
`captured_at`, and `created_at`. `capture_digest` is unique. The preflight
execution reference is a `NOT NULL` restricting FK to
`discord_roster_preflight_executions` and must point to a successful row for
the same guild and bot application. It contains no roster page,
review-package location, Discord token, email, or username.

#### `discord_assignment_review_executions`

This durable receipt identifies the signed `apply-review` command. It has
`id`, `capture_id` (restricting FK), `manifest_digest` (unique with
`capture_id`), `reviewer_principal_id` (restricting FK), `tool_revision`,
`executed_at`, `state` (`applied` or `rejected`), `reason_code`, and
`created_at`. It stores no complete manifest or selected Discord subject. An
Assignment's nullable `review_execution_id` is a restricting FK here; it is
required for `approved`, `rejected`, and `promoted` states. The review receipt
and assignment agree on capture and reviewer through a deferred constraint
trigger.

#### `staged_discord_assignments`

This is ADR-0016's durable, append-only proposal record.

| Column | Contract |
| --- | --- |
| `id` | UUID. |
| `principal_id` | `NOT NULL` FK to `principals`, `ON DELETE RESTRICT`. A deferred trigger requires its current one-to-one Member linkage. |
| `capture_id` | `NOT NULL` FK to `discord_roster_captures`, `ON DELETE RESTRICT`. |
| `provider`, `provider_subject` | `NOT NULL`, constrained to `discord` and non-empty respectively. |
| `username_snapshot` | `NOT NULL` non-empty text, immutable review evidence. |
| `state` | `proposed`, `approved`, `rejected`, `withdrawn`, `superseded`, or `promoted`. |
| `prepared_by_principal_id`, `approved_by_principal_id` | Preparer is required; approver is required only for approved/promoted rows and must differ from preparer. Both FKs restrict deletion. |
| `review_execution_id`, `approved_at`, `terminal_at`, `reason_code`, `superseded_by_id` | Review receipt FK and terminal lifecycle evidence; replacement references another Assignment and restricts deletion. |

Identity-bearing fields (`principal_id`, `capture_id`, `provider_subject`, and
`username_snapshot`) are immutable after insert. A database trigger permits
only the documented state transitions and does not permit a terminal row back
to an active state. `approved` needs a distinct approver and timestamp;
`rejected`, `withdrawn`, and `superseded` need terminal timestamp, actor, and
reason; `promoted` needs its promotion audit event.

Only `proposed` and `approved` are active. Two partial unique indexes enforce
one active candidate on each side before a permanent link exists:

```sql
CREATE UNIQUE INDEX staged_discord_assignments_active_principal
  ON staged_discord_assignments (principal_id)
  WHERE state IN ('proposed', 'approved');

CREATE UNIQUE INDEX staged_discord_assignments_active_subject
  ON staged_discord_assignments (provider, provider_subject)
  WHERE state IN ('proposed', 'approved');
```

#### `staged_discord_assignment_audit_events`

Every assignment insert and lifecycle transition appends exactly one immutable
event in the same transaction. Columns are `id`, `assignment_id` (restricting
FK), `action`, `old_state`, `new_state`, `actor_principal_id` (restricting FK),
`capture_id`, `review_execution_id`, `reason_code`, `tool_revision`,
`subject_fingerprint`, and `created_at`. The event has no raw Discord subject,
username, roster data, token, email, or review package. Update/delete are
revoked for the application role; a trigger rejects either operation as a
second line of defense.

### Permanent-link and cross-table invariants

`external_identities` keeps its existing unique indexes:

```sql
UNIQUE (provider, provider_subject)
UNIQUE (principal_id, provider)
```

For `provider = 'discord'`, database constraint triggers on both
`external_identities` and `staged_discord_assignments` enforce the following
at commit time:

1. An active Assignment cannot share either its Principal or subject with a
   Discord External Identity.
2. A Discord External Identity cannot be inserted or moved to a Principal or
   subject that has an active Assignment.
3. An active Assignment and an External Identity binding command both reject a
   matching `discord_subject_claims` row. A Continuation claim can only coexist
   with its own unbound Continuation.
4. Promotion is the sole hand-off: it changes its own `approved` Assignment to
   `promoted`, appends the audit event, then inserts the External Identity in
   the same transaction. Because the assignment is no longer active before the
   insert and the checks are deferred, no exemption flag or bypass role exists.

Each mutating command first takes transaction-scoped advisory locks in this
fixed order: `discord/principal/<principal UUID>` when a Principal is known,
then `discord/subject/<provider>/<subject>`. The constraint-trigger functions
take the same locks before cross-table reads. A hash collision only adds
serialization; it cannot merge identities. Row locks complement these key
locks: lock the Assignment or Continuation first, then the target Principal,
its Member access projection, and any matching External Identity/claim row
`FOR UPDATE`. All reads which decide a binding occur after these locks.

This lock discipline plus unique indexes is required for every Discord binding
route, including a future authenticated link and recovery implementation. It
does not use a username, email, or `SELECT`-then-insert preflight as an
integrity mechanism.

### Atomic transitions

**Invitation Acceptance.** The OAuth callback locks the Invitation, Attempt,
and live Continuation; validates expiry/fences; obtains the subject key lock;
checks External Identity, active Assignment, and claim absence; inserts the
claim; and changes the Continuation to `verified` in one transaction. A
collision changes the Continuation to `collision`, writes only its fingerprint
to support-safe audit data, and creates no Stripe state.

After Stripe is ready, finalization locks the same rows and subject key. It
rechecks the claim owner and all Invitation/Attempt fences, creates the
Principal, profiles, role, Membership, accepted Invitation/Waitlist outcome,
and Discord External Identity, deletes the claim, and marks/zeroizes the
Continuation `consumed` in one `Repo.transact/1`. The session path is not in
this transaction and no Session is created. Any exception rolls back all local
writes, leaving the Attempt and Stripe progress durable for reconciliation.

**Existing Member first use.** The OAuth callback first resolves an existing
External Identity by exact subject. Only when absent may it lock the exact
`approved` Assignment, its Principal/Member access projection, subject key,
claim, and External Identity key. It must see no claim or competing permanent
link, then atomically set Assignment to `promoted`, append its audit event,
and insert the External Identity with current OAuth metadata. Only after that
transaction commits does the ordinary atomic session-establishment path run,
and only for a Member with current club access. A callback retry observes the
External Identity and takes the normal sign-in route; a rollback leaves the
Assignment approved and creates neither identity nor Session.

### Retention and zeroization

Raw OAuth tokens are never written to any of these tables. The restricted
roster review package and raw roster pages remain outside the dashboard
database and are deleted as ADR-0016 requires. Continuations zeroize raw
subject and display metadata on `consumed`, `expired`, `cancelled`, `failed`,
and `collision`; retained lifecycle rows carry only FKs, timestamps, reason,
and keyed fingerprint. Claims are deleted on those same transitions.

Assignments and their immutable audit events are security-review records and
are retained permanently under the audit-retention policy. The assignment's
selected User ID and username snapshot are the minimum identity-bearing
history needed to explain an administrator's proposed or promoted credential
assignment; no full roster is retained. Permanent External Identities retain
the subject and latest mutable metadata only while the binding exists. A later
separately authorized recovery must write binding history/evidence references
and remove or disable the live binding under its own retention decision; it
must not repurpose an Assignment or Continuation.

### Deployment: expand → backfill/review → cutover → contract

1. **Expand.** Deploy additive tables, FKs, checks, indexes, immutable-audit
   triggers, subject/principal advisory-lock helpers, and deferred cross-table
   constraint triggers. Build non-blocking indexes concurrently where PostgreSQL
   permits, then attach/validate constraints. Deploy code that understands the
   new tables but keeps existing Discord sign-in behavior unchanged. Gate on a
   migration rehearsal, a zero-count invariant query for existing External
   Identities versus active Assignments/Claims, trigger tests, and lock-contention
   tests.
2. **Backfill/review.** Do not backfill an Assignment from `external_identities`
   or infer one from profile metadata. Existing Discord External Identities are
   already permanent links and are only observed in the conflict report. Run
   ADR-0016's capture → stage → independent review flow. Stage only rows which
   pass the new constraints; record conflicts/omissions without bypassing them.
   Gate cutover on signed review receipts, zero active-assignment conflicts,
   capture digest reconciliation, and a preflight report of counts by state.
3. **Cutover.** Enable the Continuation path for Invitation Acceptance and the
   approved-Assignment lookup in Discord OAuth callbacks. Enable claim checks
   in every Discord binding command in the same release. Monitor counts of
   continuations by state, claims older than their continuation expiry,
   Assignment state transitions, promotion success/rollback, uniqueness and
   trigger rejections, and neutral collision outcomes. Alert on any claim with
   no live verified Continuation, any active Assignment sharing a permanent
   identity, or any promotion without its audit event.
4. **Observe and rollback.** Before any `promoted` Assignment, disable the
   feature flag to stop new continuation creation and Assignment promotion;
   leave constraints and durable rows in place, expire/zeroize live
   Continuations through the normal worker, and investigate rather than delete
   claims manually. After promotion, rollback may disable new promotions but
   must preserve External Identities and immutable audits; correction is the
   dedicated recovery process, never a down migration or roster rerun. Require
   seven days with no orphan claim, cross-table invariant violation, unexpected
   uniqueness conflict, or unreconciled Stripe-linked Attempt before contract.
5. **Contract.** Remove superseded callback/link code and temporary
   compatibility reads only after the observation gate. Keep all new tables,
   constraints, indexes, triggers, and audit history. Retire the separate
   roster bot after the ADR-0016 correction window; that operational retirement
   is not a reason to remove reviewed Assignment history.

## Consequences

- A Discord account has exactly one durable live owner: no owner while only a
  Continuation claim exists, one reviewed candidate while an Assignment is
  active, or one Principal once an External Identity exists.
- The temporary claim preserves ADR-0014's payment-before-conversion barrier;
  Assignment review preserves ADR-0016's no-login-before-proof barrier.
- ALE-208 implements the expand/continuation/finalization persistence and
  ALE-209 implements the Assignment/audit/promotion persistence against this
  shared locking and trigger contract. Neither ticket may weaken the other
  path's cross-table checks.

## Considered options

- **Use one `external_identities.status` lifecycle for claims and assignments.**
  Rejected: it would make an unproven OAuth result or administrator proposal
  look like a login identity and blur different retention requirements.
- **Enforce collisions only in Ecto commands.** Rejected: concurrent callbacks,
  scripts, or future binding routes could bypass best-effort checks.
- **Store mutable Discord names on the Principal.** Rejected: they are provider
  presentation data and would make them appear authoritative for account
  recovery or login.
