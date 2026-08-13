# ADR 0016: Reviewed, staged Discord identity prefill for existing Members

**Status:** Accepted  
**Date:** 2026-08-13  
**Deciders:** DHC engineering  
**Tags:** authentication, discord, operations, member-recovery

## Context

Existing Members have Authentication Principals but may not have a Discord
External Identity. ALE-202 requires an administrator-reviewed path that lets an
existing Member use a previously identified Discord account for their first
Discord OAuth sign-in without first using a magic link. That mapping delegates
login authority: a mistaken mapping can let the controller of one Discord
account establish a Session for another Member's Principal.

Discord's guild roster is the only permitted source for the candidate Discord
accounts. Per ALE-203, its User ID is equivalent to Assent's OAuth `sub`; its
username, global display name, and guild nickname are mutable and are only
human-recognition aids. ADR-0015 and ALE-210 require a one-off roster script to
reuse DHC's existing bot through temporary audited credential access and a
recorded successful access preflight. This decision defines the prefill and
first-use contract; it neither implements the task nor creates recurring roster
synchronization.

## Decision

### Terms and lifecycle

A **Staged Discord Assignment** is a durable, administrator-authored proposed
binding between an existing Member's Authentication Principal and one Discord
provider subject. It is not an External Identity, cannot authenticate a
request, and does not establish a Session. It contains the Discord User ID as
an opaque string, the selected roster User object's `username` at capture time
as `username_snapshot`, the roster-capture and review identifiers, its target
Principal, and lifecycle/audit fields. `username_snapshot` is required review
evidence, never a reconciliation key; a changed name does not invalidate the
selected User ID.

The assignment state machine is deliberately append-only for identity-bearing
facts:

| State | Meaning | May sign in with it? |
| --- | --- | --- |
| `proposed` | A preparer has staged a roster-selected subject; a different reviewer has not approved it. | No |
| `approved` | A distinct administrator has approved the exact Principal, User ID, snapshot, and capture for first-use promotion. | Yes, only through matching Discord OAuth |
| `rejected` | The reviewer declined it. | No |
| `withdrawn` | An administrator withdrew it before promotion. | No |
| `superseded` | A correction replaced it with a newly proposed assignment. | No |
| `promoted` | The matching OAuth transaction created the External Identity. | The External Identity, not this assignment, is authoritative |

No transition edits a User ID, target Principal, username snapshot, capture ID,
or approval decision in place. A pre-use correction withdraws or supersedes the
old assignment and creates a fresh `proposed` assignment that receives fresh,
independent review. Terminal records remain as history.

### Authoritative sources and bounded roster handling

The task operates only after an ALE-210 execution record proves, from the same
controlled task environment, the existing bot's application identity and
access to the configured guild. It accepts the existing bot token only through
the task-local `DISCORD_ROSTER_BOT_TOKEN` alias plus
`DISCORD_ROSTER_GUILD_ID`; interactive OAuth credentials are rejected if
supplied. It must record the preflight execution-record ID, configured guild
ID, bot application ID, tool revision, executor, and timestamp before capture.

The task reads `GET /guilds/{guild_id}/members` as that bot, requesting up to
1000 entries per page, following the opaque `after` User-ID cursor, and obeying
Discord response rate-limit headers and each `429` `retry_after`. It must fail
closed on a duplicate User ID, malformed user object, cursor non-progress,
unexpected guild/application identity, or incomplete page sequence. It does
not query Discord email, infer a person from a name, or call an OAuth endpoint.

For a successful capture the task produces a restricted, encrypted **review
package** and a non-sensitive capture receipt. The review package contains the
roster User ID plus username, global display name, and guild nickname only as
shown by the roster, capture time, guild ID, tool revision, record count, and
digest. It may be made available only to the assigned preparer and reviewer in
the controlled administrative environment. The receipt stores the package
digest/count and capture metadata, not the complete roster. The review package
is deleted from the task environment and restricted storage after staging is
committed and its short operational correction window ends; no complete guild
roster is persisted in the dashboard database. The selected User ID and its
required username snapshot are retained on the assignment, and names remain
mutable presentation metadata.

The Member candidate list comes from the production DHC Member/Principal
relationship, not Discord, email matching, or an exported spreadsheet. It
includes each non-anonymized existing Member with its one Principal regardless
of current Membership access; inactive access affects Session eligibility, not
whether a historical login identity can be reviewed. The package joins neither
Member email nor any Discord email to a roster row. Administrators may use the
normal controlled Member administration view to identify the target Member.

### Exact operator interface and review gate

The later one-shot administrative task exposes these phases; it is never a web
request, Oban job, CI job, cron task, browser process, or general developer
command.

1. `capture`: takes no roster file and loads only the task-local
   `DISCORD_ROSTER_BOT_TOKEN` alias and `DISCORD_ROSTER_GUILD_ID` for roster
   access from its dedicated audited secret path. It verifies the recorded
   access preflight (which already checked the existing bot's expected
   application ID), captures
   every page, and emits
   `capture_id`, encrypted review-package location, digest, count, and receipt.
2. `stage`: takes `capture_id` and a signed mapping manifest. Every manifest
   row is exactly `{principal_id, discord_user_id, username_snapshot}`. It
   verifies the capture digest, that each selected User ID and snapshot occur
   in that capture, the target's current Member/Principal relationship, and all
   database constraints. It creates only `proposed` assignments and returns a
   row-by-row result containing assignment ID, target Principal ID, keyed
   Discord-subject fingerprint, and state. It never accepts a username, email,
   or display name as a selector.
3. `review`: shows a reviewer the exact proposed rows and the associated
   restricted review package. The reviewer must verify the target Member,
   selected immutable User ID, username snapshot, and capture ID, then submit a
   signed approve/reject manifest naming each assignment ID and decision. The
   reviewing administrator must be a different Principal from the preparer and
   must be authorized to administer Members. Approval is all-or-nothing per
   row; a rejected or omitted row cannot be promoted.
4. `apply-review`: verifies the reviewer signature and role, rechecks that the
   proposal still names the same facts and has not become conflicted, then
   records `approved` or `rejected`. Its receipt reports only counts, state
   transitions, assignment IDs, and keyed subject fingerprints. It does not
   print Discord User IDs, names, Member email, tokens, or the full roster.

The executor, preparer, and reviewer Principal IDs may be the same only for
capture and staging execution; an assignment's preparer and approver must
always differ. A reviewer cannot bulk-approve an uninspected capture. A new
capture or a changed selection needs a new proposal and review; a stale review
manifest is rejected. An operational outage before a committed phase is a
failure, not permission to reconstruct mappings manually or to skip review.

### Database invariants and audit history

The persistence design must make these properties database-enforced rather than
best-effort task checks:

1. An active Staged Discord Assignment (`proposed` or `approved`) has one
   target Principal and one `discord` provider subject. Partial unique indexes
   enforce at most one active assignment for a Principal and at most one active
   assignment for a Discord subject.
2. The existing External Identity uniqueness constraints continue to enforce
   one `(provider, provider_subject)` globally and one provider identity per
   Principal. A reciprocal database constraint trigger on both assignment and
   External Identity writes rejects an active assignment when its Principal
   already has a Discord External Identity or its subject is already externally
   bound, and rejects an External Identity insert when an active assignment
   exists for its Principal or subject. The sole permitted hand-off is the one
   promotion transaction that terminalizes its own assignment before inserting
   the identity; rollback restores both sides.
3. The trigger and every binding command serialize on the affected Principal
   and provider-subject keys. They also reject an active Discord subject claim.
   This preserves ADR-0014's active-subject-claim barrier: a verified
   Invitation Acceptance cannot race an administrator prefill or any other
   Discord binding path.
4. Foreign keys require the target Principal and its existing Member linkage.
   State, provider (`discord`), non-empty string subject, snapshot, capture,
   preparer, reviewer, and lifecycle timestamps have checks/not-null
   constraints appropriate to their state. `approved` requires a distinct
   approver and approval timestamp; terminal state requires a reason and actor.

Each lifecycle transition emits an immutable Assignment Audit Event in the same
transaction. The event records assignment ID, action, old/new state, actor
Principal, timestamp, capture/review/execution IDs, reason code, tool revision,
and a keyed subject fingerprint. The assignment keeps its actual selected
subject and username snapshot because those facts are necessary to bind and
explain it; routine logs and aggregate receipts use only the fingerprint. Audit
events are never rewritten or deleted by a correction. Bot tokens, OAuth
tokens, raw roster pages, Discord email, and unselected roster entries are not
audit data.

### First matching OAuth promotion

The normal Discord sign-in callback first resolves the immutable Assent `sub`.
If no External Identity exists, it may look up an `approved` Staged Discord
Assignment by exactly `(provider: discord, subject: sub)`. It must not look up
username, global name, nickname, Discord email, Member email, or a Principal
specified by the browser.

Promotion runs in one short transaction that locks the assignment, target
Principal/Member access projection, relevant External Identity keys, and the
ADR-0014 subject-claim key. It rechecks all database constraints and then:

1. returns a neutral collision/verification-in-progress result without binding
   if an External Identity or active subject claim exists;
2. changes the still-`approved` assignment to `promoted`, writes its immutable
   audit event, and inserts the Discord External Identity with the OAuth
   subject and current OAuth username metadata; and
3. establishes a Session only through the ordinary atomic session-establishment
   path and only if the target Member currently has club access.

Thus a successful first matching OAuth login needs no prior magic-link login,
but it gains no exception to Member-access or session-revocation rules. A
duplicate callback sees the permanent External Identity and follows ordinary
sign-in; a rollback leaves the assignment `approved` and no partial identity or
Session. A subject claim from Invitation Acceptance is never overridden or
removed by this flow.

An OAuth subject with no approved assignment is an omission, not an inference.
The system returns the existing neutral unable-to-sign-in outcome and offers
the ordinary supported sign-in/recovery route; it does not create an assignment,
auto-link by email, expose whether a Member exists, or establish a Session.
`proposed`, rejected, withdrawn, and superseded assignments have the same
non-promoting result. Members absent from a capture, unselected roster accounts,
and ambiguous human identifications remain omitted until a later capture,
proposal, and independent review create an approved assignment.

### Corrections, recovery, and reruns

Before promotion, the task's correction boundary is the state machine above:
withdraw/supersede, create a replacement, and obtain independent review. It
never edits an approved identity-bearing row. A stale capture is not repaired
by changing its snapshot or by using a current username: rerun capture and
review instead.

After promotion, the assignment is historical and the External Identity is the
login authority. The roster task and Member administration screens have no
operation to delete, move, or silently replace that identity. An alleged wrong
post-use mapping opens a dedicated **Discord Identity Recovery** case. The case
immediately disables Discord sign-in for the affected binding and revokes the
affected Principal's Sessions; it does not disclose the other Member or make a
new assignment available. Two distinct authorized administrators must approve
the recovery, with immutable case/audit records.

The recovery command may transfer the subject only after (a) fresh OAuth proves
control of that exact Discord User ID, (b) the destination Member proves control
of their existing DHC Principal through the normal magic-link recovery path or
an equivalent separately authenticated recovery proof, and (c) the active
subject-claim and one-to-one constraints are clear. It atomically ends the old
External Identity binding, records immutable binding history and recovery
evidence references, creates the destination binding, and leaves both
Principals with revoked Sessions. It never lets an administrator reassign a
Discord User ID based on a username, email, roster entry, or a support request
alone. The recovery implementation is a separately authenticated security
surface; this decision deliberately does not turn prefill tooling into one.

Reruns are capture-based and idempotent. A repeated `capture` creates a new
capture receipt but no assignments. Replaying the same `stage` or
`apply-review` manifest is keyed by capture digest plus manifest digest and
returns the already-created rows/transitions; it cannot duplicate audit events
or overwrite a newer decision. A changed capture or mapping creates new
proposals only for omitted/unassigned subjects. Existing `approved` or
`promoted` rows are never bulk-overwritten, withdrawn, or inferred obsolete
because a current roster no longer lists the User ID: guild membership is not
login ownership. The final execution report must separately count captured,
proposed, approved, rejected, omitted, conflicted, promoted, and unresolved
rows, with identifiers/fingerprints sufficient for follow-up but without the
complete roster.

The correction window ends only after the final report, any pre-use corrections,
and documented hand-off to the post-use recovery process. Then DHC follows
ADR-0015: revoke the executor's token access, destroy the one-shot environment,
delete the restricted roster package, and disable `GUILD_MEMBERS` if the
existing bot's established role does not need it. The bot remains installed for
that established role. A later capture requires a new approved operational
authorization and access preflight; continued bot operation is not standing
authorization for roster synchronization.

## Consequences

- The prefill is an explicit, dual-control grant of login authority rather than
  a name-matching import.
- First Discord login can be seamless for reviewed existing Members while all
  other OAuth identities remain fail-closed and non-enumerating.
- Database constraints, not a careful operator alone, maintain the one-subject
  / one-Principal relationship across pending assignments, active Invitation
  Acceptance claims, and permanent External Identities.
- Correcting a used identity is intentionally slower than correcting a staged
  row because it is a credential-recovery operation, not roster administration.

## Considered options

- **Auto-match by Discord username, email, nickname, or display name.**
  Rejected: each is mutable, non-unique, unavailable in the roster, or not the
  OAuth binding key.
- **Create External Identities during roster import.** Rejected: possession of
  the Discord account has not been proven and the import would immediately
  create login authority.
- **Allow an administrator to repair a promoted binding in the roster task.**
  Rejected: it bypasses proof of both account control and destination Principal
  control, and would make a data-import tool a credential takeover surface.
- **Run periodic roster synchronization with the existing bot.** Rejected by
  ADR-0015: guild presence is not a continuing identity or access assertion.
