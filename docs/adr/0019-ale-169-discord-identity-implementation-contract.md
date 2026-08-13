# ADR 0019: ALE-169 Discord identity implementation contract

**Status:** Accepted  
**Date:** 2026-08-13  
**Amends:** ADR-0009, ADR-0010, ADR-0013  
**Implements:** ADR-0014 through ADR-0018; ALE-169  
**Tags:** onboarding, authentication, discord, api, migration, operations

## Purpose and reconciliation

This is the implementation contract for ALE-169, not a second product-design
exercise. It resolves the earlier ADRs as follows:

- ADR-0009's optional post-acceptance Discord link is superseded for new
  members: Discord proof is required during Invitation Acceptance. Its durable
  ownership, magic-link fallback, and immutable-subject rules remain.
- ADR-0010's statement that Discord is never part of Acceptance and its
  email-match/mismatch first-sign-in paths are superseded. Its atomic
  Principal/Member birth, authoritative invitation email, and no-session
  boundary remain.
- ADR-0013's durable Attempt and Stripe seam remain. An Acceptance Attempt now
  requires a consumed verified Discord Continuation before any Stripe mutation.
- ADR-0014 defines the prospective-member proof and transaction boundaries;
  ADR-0015–0017 define the reviewed existing-member path and its persistence;
  ADR-0018 supplies subject-only sign-in, gates, recovery, and rollback policy.

The only enduring Discord-to-Principal binding is `external_identities`. A
Continuation, Subject Claim, and Staged Assignment are deliberately different
temporary/pre-use states. A display name is never an identity or authorization
fact.

## Required behavior and transaction boundaries

### Invitation Acceptance state machine

The server alone owns state transitions. The browser may render a safe view and
request an allowed action; it cannot supply an Attempt, Continuation, Principal,
Discord subject, price, or Stripe state.

| State/event | Server obligation | Stripe / Session boundary |
| --- | --- | --- |
| `verify_invitation` | Verify invitation email and date of birth; lock Invitation; create or resume its single active Attempt and an `awaiting_oauth` Continuation in the protected acceptance browser session. | No Stripe, Principal, identity, Membership, or DHC Session. |
| OAuth start/callback | Bind Assent state and PKCE to that browser session. Validate callback, invitation/attempt fences, and expiry; atomically change Continuation to `verified` and insert its Subject Claim. | Callback has no Stripe work and never calls ordinary sign-in. |
| collision/cancel/failure/expiry | Compare-and-set a terminal Continuation, release the Claim, zeroize raw subject and display metadata, and close the Attempt where ADR-0014 requires. | No Stripe; no identity or Session. |
| `continue` | Lock verified Continuation, Attempt, Invitation, and Claim; consume the browser-held Continuation into the Attempt exactly once. | Only a successful consume permits the Attempt's existing Stripe progression. |
| retry/reconciliation | Resume the same Attempt, Claim, and stable Stripe idempotency keys. | Never repeat OAuth or create a second Attempt. |
| finalization | In one `Repo.transact/1`, lock all workflow rows and create/claim profile, Principal, MemberProfile, `member` Role, Membership, accepted Invitation, Waitlist outcome, and Discord External Identity; delete Claim and consume/zeroize Continuation. | Local writes are all-or-nothing. No authenticated Session or magic link is created. |

An Attempt begun before `invitations.expires_at` has the ADR-0014 expiry fence:
it may finish/reconcile after wall-clock expiry. No new verification,
Continuation, or Attempt starts after expiry. A finalization exception rolls
back every local conversion write but retains the durable Attempt and Stripe
progress for reconciliation.

The existing-member callback first looks up an exact External Identity. Only
when absent may it promote one exact approved Assignment in a short locked
transaction. Session establishment runs only after that transaction commits
and only through ADR-0011. It is not part of promotion. All binding routes use
ADR-0017 advisory-lock order and deferred cross-table constraints.

## Phoenix, Ecto, and Oban obligations

1. The public domain seam is `Dhc.Onboarding`: verification, safe state read,
   OAuth start/callback completion, cancellation, continue, retry, and
   reconciliation. Controllers do not orchestrate Stripe, cross-table identity
   checks, or state transitions.
2. Reuse the existing Assent Discord protocol adapter (state, PKCE, code
   exchange, normalized `sub`); add an explicit Acceptance purpose. The callback
   must not call `Auth.sign_in_with_discord/1` or an authenticated-link command.
3. Add the ADR-0017 tables, checks, partial unique indexes, constraint triggers,
   immutable audit triggers, and subject/principal advisory-lock helpers. Use
   UUIDs, `timestamptz`, and `created_at`/`updated_at` conventions. Application
   schemas declare `created_at`, not `inserted_at`.
4. `external_identities` retains `UNIQUE(provider, provider_subject)` and
   `UNIQUE(principal_id, provider)`. It owns only allowlisted current metadata:
   `username`, `global_name`, `avatar`, and optionally provider email/
   `email_verified` until ADR-0018 contracts the scope. OAuth tokens, raw roster
   pages, and unbounded metadata history are prohibited.
5. Use a keyed HMAC subject fingerprint for audit/metrics correlation; do not
   use a reversible or unhashed digest. Terminal/consumed Continuations retain
   lifecycle fields and fingerprint only; delete Claims and null raw subject and
   display metadata in the same transaction.
6. Persist a unique Oban job with the Attempt whenever a durable external
   progression/reconciliation obligation is recorded. Workers re-lock and
   re-read Attempt state, use its stable provider idempotency keys, and are safe
   to run repeatedly. Expiry/zeroization uses a separately unique maintenance
   job. Jobs never carry OAuth credentials, raw subject, payment secrets, or
   browser state in arguments.
7. Stripe webhooks and reconciliation advance the Attempt through the existing
   Onboarding Stripe seam; they cannot finalize if the verified, consumed
   Continuation/Claim fence is absent. Finalization is retried from durable state
   rather than from a controller redirect.

## API and generated-client contract

OpenAPI at `apps/phoenix/priv/api/openapi.yaml` is authoritative. Add one
`Onboarding` tag and generate Phoenix stubs and the TypeScript client together
with `mise run api-gen`; expose generated functions/types from the four relevant
blocks of `packages/api-client/src/index.ts`. Cookies remain same-origin; no
caller forwards a credential manually.

| Operation | Contract |
| --- | --- |
| `POST /api/onboarding/invitation-acceptance/verify` | Accepts invitation credential fields; creates/resumes protected flow state and returns a safe view. |
| `GET /api/onboarding/invitation-acceptance` | Reads the refresh-safe view for this browser only. Missing proof yields `restart_verification`, not an identifier lookup. |
| `GET /api/onboarding/invitation-acceptance/discord` | Full browser navigation; validates `awaiting_oauth`, stores purpose/Continuation beside Assent state + PKCE, then redirects to Discord. |
| Discord callback | Browser-only redirect to `/accept-invitation/resume`; no JSON claim, token, or authenticated-session cookie. |
| `POST /api/onboarding/invitation-acceptance/discord/cancel` | Pre-consumption only; compare-and-set ends the Continuation/Claim and returns server state. |
| `POST /api/onboarding/invitation-acceptance/continue` | Consumes verified proof and returns the current payment/progress state; duplicates return that same Attempt projection. |
| `POST /api/onboarding/invitation-acceptance/retry` | Only resumes a server-declared recoverable Attempt transition; never makes a new proof or Attempt. |

Every JSON success is `{ data: InvitationAcceptanceView }`; errors use
`{ errors: { detail: string } }`. The view is a discriminated state union:
`verify_invitation`, `awaiting_oauth`, `restart_verification`,
`discord_verified`, `payment_pending`, `payment_needs_action`,
`payment_terminal`, `discord_unavailable`, `discord_collision`,
`invitation_expired`, and `accepted`.

`discord_verified` exposes only invitation email and current safe Discord
presentation (`username`, optional avatar URL). `payment_needs_action` exposes
only a server-authorized payment descriptor. The required initial descriptor is
`{ kind: "redirect", url: string }`, where `url` is a Stripe URL minted by the
server for the current Attempt; SvelteKit performs a full navigation and returns
to the same resume route. Complimentary membership returns no descriptor.
Amounts, currencies, provider IDs, client secrets, Attempt IDs, Continuation
IDs, subject, claim state, OAuth state/PKCE, Discord email, and DHC session
credentials are never in the view, URL, local storage, or analytics.

Malformed request payloads are `422`; missing/expired browser proof is `409`
with the restart state; stale/disallowed state transitions are `409` with the
current safe view when safe, otherwise the neutral error; unauthenticated
Acceptance browser mutations failing CSRF are `403`; and unexpected provider or
finalization uncertainty is `503`/`500` with a non-enumerating support-safe
detail and a durable reconciliation outcome. A Discord collision is a normal
`200` `discord_collision` view, not a `404`/`403` distinction. Ordinary
subject-only sign-in and OAuth failure remain non-enumerating.

## SvelteKit contract

Build `/accept-invitation` and `/accept-invitation/resume` as a state-driven
flow using the generated client. All mutation requests use ordinary CSRF
protection. OAuth departure is a full navigation, never `fetch`. The resume
route is safe to reload and contains no bearer material.

Render the ALE-207 copy and boundaries: Acceptance is registration, requires
Discord verification, and does not sign in or send a magic link. Show
`@username` only as a mutable snapshot; **Use a different Discord account** is
available only before consumption. Payment progress is server-driven. Final
success offers only **Go to sign in**, prefilled visually with invitation email,
to the normal rate-limited magic-link request page. Do not display dashboard
navigation, signed-in chrome, countdown authority, raw technical failure, or
account/membership information on collision.

## Security and privacy

- Protect all flows with same-origin secure, HttpOnly acceptance-session cookies,
  CSRF, Assent state/PKCE, strict callback redirect allowlists, and short
  server-enforced expiry. This browser session is transport state, not a DHC
  Session.
- Collision, omission, outage, inactive access, and recovery responses must not
  reveal a Principal, Member, email, Assignment, claim, or link existence.
- Roster review packages are restricted/encrypted outside the dashboard DB and
  are deleted after the correction window. Retain only selected subject,
  immutable snapshot, capture/review receipts, and permanent security audit
  records as ADR-0016/0017 prescribe.
- The separate roster bot has no product/runtime role after prefill. Its token,
  guild roster, and OAuth credentials are separate and never enter application
  logs, tables, Oban arguments, OpenAPI, or frontend state.
- Recovery is a separately authenticated, dual-controlled security operation;
  admin/member screens do not get direct identity transfer/delete operations.

## Migration, gates, rollout, and operations

Follow this order; later steps must not begin early:

1. **Expand:** deploy ADR-0017 additive persistence, locks, triggers, indexes,
   audit protections, feature gates, metric/event definitions, and dark-path
   code. Rehearse migrations and verify zero existing-identity versus active-row
   conflicts.
2. **Backfill/review:** do not synthesize Assignments from existing identities
   or metadata. Execute ADR-0015/0016 provisioning, capture, stage, independent
   review, and receipts; report omissions/conflicts without bypass.
3. **Prepared verification:** deploy Acceptance routes/UI and workers behind
   `prepared`; run callback, replay, payment, lock-contention, and outage drills
   with production-like evidence. No Assignment promotes and no new acceptance
   requires Discord yet.
4. **Cutover:** reach `cutover_ready`, then make one staffed,
   transaction-consistent transition to `subject_only_active`. Enable
   continuation enforcement and Assignment promotion together; disable legacy
   Discord email reconciliation in the same release.
5. **Observe:** operate the ADR-0018 dashboard/runbook for at least 14 healthy
   consecutive days and one invitation/membership cycle. A fault pauses Discord
   (`discord_sign_in_paused`) and uses magic-link recovery; it never restores
   email linking. Existing durable state remains.
6. **Contract:** after ADR-0018 removal criteria, remove legacy code and Discord
   `email` scope, retain constraints/audits, and retire the roster bot after its
   correction window. Roll forward compatible code rather than down-migrating.

Metrics and alerts must cover OAuth start/callback/cancel/error latency,
Continuation/Claim lifecycle and age, collisions before Stripe, Attempt/Stripe
reconciliation, finalization rollbacks, Assignment transitions/promotions,
subject-only sign-in outcomes, magic-link fallback, gate changes, trigger/
uniqueness rejections, and invariant scans. Alert immediately for orphaned
Claims, active Assignment/permanent-link overlap, missing promotion audit,
email-link attempts after cutover, or unreconciled finalization.

## Required tests and acceptance criteria

Implementation tickets are complete only when they prove the following:

1. **Proof and replay:** credential, OAuth state/PKCE, browser-loss, callback,
   cancel, expiry, change-account, resume, and retry paths preserve the state
   machine; no URL/client storage leaks sensitive identifiers.
2. **Atomicity:** callback never creates Stripe state/Principal/identity/Session;
   finalization creates the entire conversion and identity or nothing; rollback
   and retries do not duplicate Membership, Role, Attempt, External Identity,
   Claim, or audit event.
3. **Concurrency:** real Postgres tests cover same-subject concurrent
   acceptance, claim versus Assignment/promotion/link, finalization conflicts,
   advisory-lock order, deferred constraints, and promotion rollback.
4. **Access:** new acceptance never creates a Session; existing identity and
   approved Assignment promotion use ADR-0011 and deny inactive access; access
   loss revokes sessions; magic link remains usable as the fallback.
5. **API/UI:** generated OpenAPI/controller/client contracts cover every
   endpoint/state/error. Svelte tests cover all safe views, full OAuth
   navigation, refresh, server-directed payment redirect, neutral collision,
   and sign-in-only success. No bare Phoenix fetches.
6. **Privacy/security:** tests assert no email/name reconciliation after cutover,
   no enumeration, zeroization, restricted audit fields, no token/job leakage,
   CSRF, and recovery's two approvals plus both fresh proofs.
7. **Operations:** migration rehearsal, feature-gate audit, worker idempotency,
   dashboards, alerts, invariant scans, outage/pause drill, prefill receipts,
   and the 14-day contract gate have recorded evidence.

| Requirement | Source | Evidence |
| --- | --- | --- |
| Required new-member Discord proof without Session | ADR-0014, ALE-207 | State-machine, callback, finalization, and UI tests |
| Existing-member reviewed first-use promotion | ADR-0015–0017 | Migration, audit, constraint, and OAuth-promotion tests |
| Subject-only sign-in and recovery | ADR-0018 | Cutover gate, callback, recovery, and outage tests |
| Durable Stripe progression | ADR-0013 | Attempt/Oban/idempotency/reconciliation tests |
| API-first frontend integration | ADR-0003, ALE-207 | OpenAPI generation, client exports, contract and Svelte tests |

## Explicitly out of scope

This contract does **not** add guild enrollment, Membership-driven guild
cleanup, invitation analytics, or implementation slicing. Guild roster access
exists only for the one-off, separately reviewed existing-member prefill;
Membership access remains a DHC Session policy and does not grant or revoke
Discord guild membership.
