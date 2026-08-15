# ADR 0019: ALE-169 Discord identity implementation contract

**Status:** Accepted  
**Date:** 2026-08-13  
**Amended:** 2026-08-14 — retain the existing Stripe Elements/ConfirmationToken payment experience; remove the mandatory hosted-Checkout redirect; define protected pricing, Stripe-action, retry, and payment-secret lifecycle contracts
**Amended:** 2026-08-15 — descope dual-controlled Discord identity recovery; a member who loses their Discord account uses normal magic-link sign-in followed by manual administrator action, with no dedicated recovery workflow
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
- ADR-0013's durable Attempt and server-authorized Stripe seam remain, including
  the existing Stripe Elements/ConfirmationToken collection experience. An
  Acceptance Attempt now requires a consumed verified Discord Continuation
  before any Stripe mutation. This contract does not require Stripe Checkout or
  replace the established payment form.
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

| State/event                     | Server obligation                                                                                                                                                                                                                                                                                         | Stripe / Session boundary                                                                                                                                                                                                         |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `verify_invitation`             | Verify invitation email and date of birth; lock Invitation; create or resume its single active Attempt and an `awaiting_oauth` Continuation in the protected acceptance browser session.                                                                                                                  | No Stripe, Principal, identity, Membership, or DHC Session.                                                                                                                                                                       |
| OAuth start/callback            | Bind Assent state and PKCE to that browser session. Validate callback, invitation/attempt fences, and expiry; atomically change Continuation to `verified` and insert its Subject Claim.                                                                                                                  | Callback has no Stripe work and never calls ordinary sign-in.                                                                                                                                                                     |
| collision/cancel/failure/expiry | Compare-and-set a terminal Continuation, release the Claim, zeroize raw subject and display metadata, and close the Attempt where ADR-0014 requires.                                                                                                                                                      | No Stripe; no identity or Session.                                                                                                                                                                                                |
| `continue`                      | Lock verified Continuation, Attempt, Invitation, and Claim; consume the browser-held Continuation into the Attempt exactly once.                                                                                                                                                                          | Only a successful consume permits the browser to enter the existing Stripe Elements payment step. It does not itself create Stripe state.                                                                                         |
| payment submission              | Accept the existing membership details, coupon code, and browser-created Stripe ConfirmationToken for the protected Attempt; re-lock and verify the consumed Continuation/Claim fence; atomically record an immutable payment-submission generation before invoking the existing server-side Stripe seam. | Phoenix remains authoritative for pricing, coupon validation, Stripe progression, and finalization. The browser cannot supply an amount, currency, customer, Attempt, generation, idempotency key, or provider progression state. |
| retry/reconciliation            | Resume the same Attempt, Claim, immutable payment-submission generation, and stable per-operation Stripe idempotency keys. A replacement generation is allowed only after the server has proved that the prior token-bearing operation cannot have progressed.                                            | Never repeat OAuth or create a second Attempt. Never reuse an idempotency key with changed Stripe parameters.                                                                                                                     |
| finalization                    | In one `Repo.transact/1`, lock all workflow rows and create/claim profile, Principal, MemberProfile, `member` Role, Membership, accepted Invitation, Waitlist outcome, and Discord External Identity; delete Claim and consume/zeroize Continuation.                                                      | Local writes are all-or-nothing. No authenticated Session or magic link is created.                                                                                                                                               |

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
   OAuth start/callback completion, cancellation, continue, payment submission,
   retry, and reconciliation. Controllers do not orchestrate Stripe,
   cross-table identity checks, or state transitions.
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
   re-read Attempt state, use the stable idempotency key recorded for each
   immutable provider operation, and are safe to run repeatedly. Expiry/
   zeroization uses a separately unique maintenance job. Jobs never carry OAuth
   credentials, raw subject, payment secrets, or browser state in arguments.
7. Stripe webhooks and reconciliation advance the Attempt through the existing
   Onboarding Stripe seam; they cannot finalize if the verified, consumed
   Continuation/Claim fence is absent. Finalization is retried from durable state
   rather than from a controller redirect.
8. Store each payment-submission generation in dedicated restricted fields or a
   dedicated child record, never in general `acceptance_data`. The record owns
   its immutable canonical submission fields, keyed ConfirmationToken
   fingerprint, encrypted transient token, provider-reported expiry, lifecycle,
   dispatch/outcome facts, and per-operation idempotency keys. Only the
   Onboarding payment command and its reconciliation worker may read the
   encrypted token.

## API and generated-client contract

OpenAPI at `apps/phoenix/priv/api/openapi.yaml` is authoritative. Add one
`Onboarding` tag and generate Phoenix stubs and the TypeScript client together
with `mise run api-gen`; expose generated functions/types from the four relevant
blocks of `packages/api-client/src/index.ts`. Cookies remain same-origin; no
caller forwards a credential manually.

| Operation                                                   | Contract                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /api/onboarding/invitation-acceptance/verify`         | Accepts invitation credential fields; creates/resumes protected flow state and returns a safe view.                                                                                                                                                                                                                        |
| `GET /api/onboarding/invitation-acceptance`                 | Reads the refresh-safe view for this browser only. Missing proof yields `restart_verification`, not an identifier lookup.                                                                                                                                                                                                  |
| `GET /api/onboarding/invitation-acceptance/discord`         | Full browser navigation; validates `awaiting_oauth`, stores purpose/Continuation beside Assent state + PKCE, then redirects to Discord.                                                                                                                                                                                    |
| Discord callback                                            | Browser-only redirect to `/accept-invitation/resume`; no JSON claim, token, or authenticated-session cookie.                                                                                                                                                                                                               |
| `POST /api/onboarding/invitation-acceptance/discord/cancel` | Pre-consumption only; compare-and-set ends the Continuation/Claim and returns server state.                                                                                                                                                                                                                                |
| `POST /api/onboarding/invitation-acceptance/continue`       | Consumes verified proof and returns `payment_ready` for the protected Attempt; duplicates return that same Attempt projection without creating Stripe state.                                                                                                                                                               |
| `GET /api/onboarding/invitation-acceptance/pricing`         | Protected, read-only pricing preview for the browser session's consumed Attempt. It accepts only an optional coupon candidate; no Invitation, Attempt, amount, currency, price, or provider identifier.                                                                                                                    |
| `POST /api/onboarding/invitation-acceptance/payment`        | Submits the established membership details, coupon candidate, and Stripe Elements ConfirmationToken against the protected Attempt. The server revalidates price and coupon, atomically records or resumes a payment-submission generation, advances the durable Stripe seam, and finalizes when provider progress permits. |
| `POST /api/onboarding/invitation-acceptance/retry`          | Resumes only the server-declared recoverable operation with its recorded generation, parameters, and key. It accepts no ConfirmationToken, coupon, Attempt, or provider identifier and never makes a new proof or Attempt.                                                                                                 |

The pricing operation succeeds with `{ data: PricingPreview }`. Every acceptance
state operation succeeds with `{ data: InvitationAcceptanceView }`; all errors
use `{ errors: { detail: string } }`. The view is a discriminated state union:
`verify_invitation`, `awaiting_oauth`, `restart_verification`,
`discord_verified`, `payment_ready`, `payment_pending`, `payment_needs_action`,
`payment_terminal`, `discord_unavailable`, `discord_collision`,
`invitation_expired`, and `accepted`.

`discord_verified` exposes only invitation email and current safe Discord
presentation (`username`, optional avatar URL). `payment_ready` authorizes the
existing Stripe Elements membership-payment form for this protected browser; it
is not a Stripe operation and carries no amount or caller-selectable provider
state. The form continues to collect membership details and an optional coupon,
creates a Stripe ConfirmationToken in the browser, and submits it to Phoenix.
Complimentary membership uses the same form and existing 100% discount path.

### Protected pricing contract

The pricing operation is available only in `payment_ready` to the same protected
acceptance browser session. It resolves the Attempt and Invitation from that
session, performs no Stripe mutation, and returns an authoritative
`PricingPreview` containing:

- currency and all money values as integer minor units;
- monthly and annual recurring fees, prorated monthly and annual components,
  and the first-payment total;
- next monthly and annual billing dates; and
- either no promotion or the validated promotion code, discount percentage,
  and whether it applies to the first payment or recurring fees.

The coupon query value is only a candidate for preview. A preview neither
reserves a promotion nor becomes payment authority. Payment submission resolves
the current server-side price configuration and promotion again and rejects a
coupon that changed or expired; it never accepts a preview, amount, currency, or
date back from the browser. Invalid coupons use the normal `422` error shape.

### Payment submission and retry contract

A payment-submission generation is immutable after it is recorded. Under the
Attempt lock, the first valid `/payment` request in `payment_ready` canonicalizes
the membership fields and coupon candidate, allocates the next generation, and
commits its ConfirmationToken, keyed token fingerprint, and token-bearing Stripe
operation's idempotency key before any provider call. The key is stable for that
exact operation and parameter set. Downstream customer, SetupIntent,
subscription, invoice, and payment operations likewise have separately recorded
stable keys committed before execution; a key is never reused with different
parameters. Provider objects created by the workflow carry an opaque Attempt and
generation correlation in Stripe metadata so reconciliation does not depend on
browser input.

The following outcomes are mandatory:

| Submission/retry event                                                                                      | Outcome                                                                                                                                                                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Duplicate request with the same token and canonical fields                                                  | Resume or return the current generation's safe view. Do not allocate a generation or repeat a completed provider step.                                                                                                                                                                           |
| Concurrent/different token or changed fields while a generation is active                                   | Reject with `409` and the current safe view. Do not replace provider input that may already be in flight.                                                                                                                                                                                        |
| Transport timeout or any unknown Stripe outcome                                                             | Return `payment_pending`; retain the original token, exact parameters, and key until reconciliation proves the result. Retry the exact call only while Stripe still guarantees the key; token expiry or a later "already used" response alone does not prove that the original operation failed. |
| Definitive invalid/expired/rejected token before the token-bearing operation could create provider progress | Close that generation, zeroize its raw token, and return `payment_ready` with a support-safe request for new payment details. A later `/payment` request may allocate a new generation and a new token-bearing-operation key on the same Attempt.                                                |
| Durable SetupIntent or later provider progress exists                                                       | Record the provider identifier and zeroize the raw token. All retries continue from recorded provider progress; a replacement token/generation is forbidden.                                                                                                                                     |
| Stripe requires customer action                                                                             | Return `payment_needs_action` as defined below and retain the Attempt and Claim.                                                                                                                                                                                                                 |
| Recoverable asynchronous provider work                                                                      | Return `payment_pending`; webhook/reconciliation owns advancement.                                                                                                                                                                                                                               |
| Unrecoverable failure after possible provider progress                                                      | Reconcile and clean up first. Only then return `payment_terminal`, close the Attempt, and release/zeroize the Continuation and Claim.                                                                                                                                                            |

Replacement never creates a second Attempt, repeats Discord OAuth, or releases
the subject Claim. A deterministic browser validation error before the server
records a generation creates no durable submission. `/retry` can only replay a
recorded operation; a replacement ConfirmationToken is submitted through
`/payment` only after the server has returned `payment_ready`.

Stripe may prune an idempotency result after its documented retention window.
Before that boundary, reconciliation retrieves the ConfirmationToken and any
recorded/correlated Intent or other provider object. After the boundary it never
blindly repeats a create or confirm request: it resolves the token's
`setup_intent`/`payment_intent` association and the workflow's Stripe metadata
first. It can authorize a replacement generation only when those checks prove
that the token-bearing operation created no provider progress.

### Stripe action and return contract

`payment_needs_action` has exactly one generated-client shape:
`{ state: "payment_needs_action", action: { kind: "stripe_js", clientSecret:
string } }`. The server emits it only for the recorded Intent whose status is
`requires_action`. It does not expose Stripe's raw `next_action`, an arbitrary
provider URL, or a caller-selectable action. `payment_pending` carries no action.
An unrecognized provider action is not forwarded to the browser; the Attempt
remains pending and raises an operator-visible reconciliation alert until the
server adapter supports it or resolves it.

The client secret is customer-scoped transient output to this protected browser,
not a durable browser credential. SvelteKit passes it directly from the response
to `stripe.handleNextAction({ clientSecret })`, keeps it only in memory, and
discards it before reading the protected current view or invoking `/retry`.
Phoenix advances state only from its recorded provider identifiers, Stripe
responses/webhooks, and reconciliation; it never trusts an Intent, secret, or
action result posted back by the browser. The server does not persist the client
secret; when a refresh still requires action, it retrieves the recorded Intent
server-side and emits the current secret in a new protected response.

The ConfirmationToken is created with one allowlisted `return_url`,
`/accept-invitation/stripe-return`. Some Stripe-managed actions append an Intent
identifier and client secret to that URL. This callback is the sole exception to
the clean-URL rule: application, proxy, CDN, error-reporting, and analytics
configuration must suppress or redact its query string before logging; the
route renders no application page or third-party asset, sets `Cache-Control:
no-store` and `Referrer-Policy: no-referrer`, ignores the query as authority,
and immediately returns `303` to the query-free `/accept-invitation/resume`.
The application never constructs a client-secret URL itself. A non-redirecting
Stripe.js action returns directly and then refreshes the same protected view.

Amounts or currencies supplied by the caller, provider customer/subscription
IDs, Attempt IDs, generations, idempotency keys, Continuation IDs, subject, claim
state, OAuth state/PKCE, Discord email, and DHC session credentials are never in
the safe view, URL, local storage, or analytics. Client secrets are present only
in the protected action response and, when Stripe itself redirects, transiently
on the hardened return route above.

### Payment-secret minimization

The ConfirmationToken is accepted only in the `/payment` request body. Before a
token-bearing Stripe call, its raw value may exist only in the active generation's
dedicated server-only field, protected with authenticated application-level
encryption under a payment-secret key. It is excluded from general acceptance
JSON, `stripe_state`, OpenAPI responses, logs, traces, errors, analytics, audit
events, support tools, and Oban arguments. A keyed fingerprint may remain for
duplicate detection; it must not be reversible.

The raw token is retained only while the recorded token-bearing operation is
undispatched or has an unknown outcome. It is zeroized in the same database
transaction that records a definitive pre-progression rejection, durable
SetupIntent/provider progress, or terminal/accepted Attempt outcome. An
undispatched token that reaches Stripe's token expiry becomes replacement-ready
and is zeroized. Expiry after dispatch does not authorize replacement: the
worker must first reconcile the original key and provider result. No closed or
accepted Attempt and no superseded generation retains a raw ConfirmationToken.

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

After `continue` returns `payment_ready`, reuse the established membership
details, coupon, validation, and Stripe Elements form. Discord verification adds
an authorization fence before that form; it does not introduce a parallel form
or replace Elements with Stripe Checkout. OAuth remains a full navigation.
Payment leaves the app only when Stripe requires provider authentication for
the submitted Elements payment method. Pricing uses the protected Attempt-bound
operation, and Stripe action handling uses only the discriminated
`payment_needs_action` contract above.

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
- Roster export is a one-off script authenticated by DHC's existing bot. The
  script is not added to that bot's runtime; its task-local token access, guild
  roster, and OAuth credentials never enter application logs, tables, Oban
  arguments, OpenAPI, or frontend state.
- Recovery is a separately authenticated, dual-controlled security operation;
  admin/member screens do not get direct identity transfer/delete operations.

## Migration, gates, rollout, and operations

Follow this order; later steps must not begin early:

1. **Expand:** deploy ADR-0017 additive persistence, locks, triggers, indexes,
   audit protections, feature gates, metric/event definitions, and dark-path
   code. Rehearse migrations and verify zero existing-identity versus active-row
   conflicts.
2. **Backfill/review:** do not synthesize Assignments from existing identities
   or metadata. Execute ADR-0015/0016 existing-bot access preflight, capture,
   stage, independent review, and receipts; report omissions/conflicts without
   bypass.
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
   `email` scope, retain constraints/audits, revoke the roster script's bot-token
   access after its correction window, and disable `GUILD_MEMBERS` if the bot's
   established role does not need it. Keep the existing bot for that role. Roll
   forward compatible code rather than down-migrating.

Metrics and alerts must cover OAuth start/callback/cancel/error latency,
Continuation/Claim lifecycle and age, collisions before Stripe, Attempt/Stripe
reconciliation, payment-generation/token-retention age, finalization rollbacks,
Assignment transitions/promotions, subject-only sign-in outcomes, magic-link
fallback, gate changes, trigger/uniqueness rejections, and invariant scans.
Alert immediately for orphaned Claims, an expired undispatched token that was
not zeroized, active Assignment/permanent-link overlap, missing promotion audit,
email-link attempts after cutover, or unreconciled finalization.

## Required tests and acceptance criteria

Implementation tickets are complete only when they prove the following:

1. **Proof and replay:** credential, OAuth state/PKCE, browser-loss, callback,
   cancel, expiry, change-account, resume, and retry paths preserve the state
   machine; the hardened Stripe return route strips provider-appended secrets
   before resume and no other URL/client storage leaks sensitive identifiers.
2. **Atomicity:** callback never creates Stripe state/Principal/identity/Session;
   finalization creates the entire conversion and identity or nothing; rollback
   and retries do not duplicate Membership, Role, Attempt, External Identity,
   Claim, or audit event.
3. **Concurrency:** real Postgres tests cover same-subject concurrent
   acceptance, same-token duplicates, competing-token submissions, definitive
   replacement versus unknown-outcome replay, idempotency-window expiry,
   token-to-Intent reconciliation, claim versus Assignment/promotion/link,
   finalization conflicts, advisory-lock order, deferred constraints, and
   promotion rollback.
4. **Access:** new acceptance never creates a Session; existing identity and
   approved Assignment promotion use ADR-0011 and deny inactive access; access
   loss revokes sessions; magic link remains usable as the fallback.
5. **API/UI:** generated OpenAPI/controller/client contracts cover every
   endpoint/state/error. Svelte tests cover all safe views, full OAuth
   navigation, refresh, reuse of the existing Stripe Elements/details/coupon
   form after `payment_ready`, protected pricing and payment-time revalidation,
   Stripe.js action and sanitized return, neutral collision, and sign-in-only
   success. No bare Phoenix fetches.
6. **Privacy/security:** tests assert no email/name reconciliation after cutover,
   no enumeration, ConfirmationToken encryption and lifecycle zeroization,
   callback query redaction, restricted audit fields, no token/job leakage,
   CSRF, and recovery's two approvals plus both fresh proofs.
7. **Operations:** migration rehearsal, feature-gate audit, worker idempotency,
   dashboards, alerts, invariant scans, outage/pause drill, prefill receipts,
   and the 14-day contract gate have recorded evidence.

| Requirement                                       | Source            | Evidence                                                      |
| ------------------------------------------------- | ----------------- | ------------------------------------------------------------- |
| Required new-member Discord proof without Session | ADR-0014, ALE-207 | State-machine, callback, finalization, and UI tests           |
| Existing-member reviewed first-use promotion      | ADR-0015–0017     | Migration, audit, constraint, and OAuth-promotion tests       |
| Subject-only sign-in and recovery                 | ADR-0018          | Cutover gate, callback, recovery, and outage tests            |
| Durable Stripe progression                        | ADR-0013          | Attempt/generation/Oban/idempotency/reconciliation tests      |
| API-first frontend integration                    | ADR-0003, ALE-207 | OpenAPI generation, client exports, contract and Svelte tests |

## Explicitly out of scope

This contract does **not** add guild enrollment, Membership-driven guild
cleanup, invitation analytics, or implementation slicing. The existing bot is
reused only to authenticate the one-off, separately reviewed existing-member
roster export; Membership access remains a DHC Session policy and does not grant
or revoke Discord guild membership.

## Payment UI clarification

Mandatory Stripe-hosted Checkout was considered and rejected. The existing
Stripe Elements flow is already server-authorized: the browser creates only a
ConfirmationToken, while Phoenix owns Invitation and Attempt validation,
authoritative pricing, coupon validation, Stripe customer/subscription
progression, idempotency, and atomic Member finalization. Replacing that flow
with Checkout would duplicate the established membership-details and coupon UI
without strengthening the Discord, payment, or transaction boundaries required
by this ADR.

The required change is therefore ordering, not payment-product replacement:
Invitation credentials and Discord OAuth are verified first; `continue`
consumes that proof into the durable Attempt; only then may the existing Elements
form submit payment input to the server-owned Onboarding command.
