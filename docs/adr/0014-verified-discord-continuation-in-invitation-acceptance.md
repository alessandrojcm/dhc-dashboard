# Verified Discord continuation in Invitation Acceptance

**Status:** Accepted  
**Date:** 2026-08-13  
**Amends:** ADR-0010, ADR-0013  
**Tags:** onboarding, invitations, authentication, discord, oauth, payments

## Context

ADR-0009 makes the Invitation email authoritative and treats Discord's provider subject as the identity key. ADR-0010 correctly made Invitation Acceptance the atomic birth of the Principal and Member, but specified Discord only after acceptance. ALE-202 now requires a prospective Member to prove a Discord account during acceptance. OAuth is necessarily a redirect and Stripe work can outlive a database transaction, so neither the OAuth callback nor a payment retry may create a Principal, Session, or External Identity independently of the final conversion.

The OAuth protocol adapter already preserves Assent's CSRF state and PKCE verifier in the browser's ordinary Phoenix session. That session is transport state, not a DHC authenticated Session. The verified provider subject must nevertheless survive the redirect and coordinate safely with the durable Invitation Acceptance Attempt required by ADR-0013.

## Decision

### Durable continuation, not a signed assertion

An **Invitation Acceptance Discord Continuation** is a durable, invitation-bound verification record. It is not an External Identity, never authorizes requests, and cannot exist for a Principal. It has a random opaque identifier, its Invitation and active Invitation Acceptance Attempt identifiers, a state, timestamps, and—while needed—the Discord provider subject and mutable display metadata. The record is created only after the caller proves the pending Invitation's email and date of birth.

The credential-verification proof remains a 15-minute Phoenix token as in ADR-0010. Redeeming it creates or resumes the Invitation's one active Attempt and creates a fresh `awaiting_oauth` Continuation. The Continuation expires at the earlier of 15 minutes after creation and the Invitation's normal expiry. Re-verifying credentials before either expiry may resume the same Attempt but must create a new Continuation after an expired, cancelled, or failed one; it must not extend a live Continuation. The browser receives only the opaque Continuation identifier in its protected Phoenix session. It is not placed in a URL, OAuth `state`, client-side storage, or a signed bearer token.

Starting OAuth records the Continuation identifier next to Assent's per-browser state and PKCE session parameters. The OAuth callback must restore and validate those parameters, load the same `awaiting_oauth` Continuation, and require that its Invitation and Attempt are still current. A missing or replaced browser session, invalid OAuth state, PKCE failure, provider error, or expired Continuation completes no verification and makes no Stripe mutation; the prospective Member restarts OAuth through the same Attempt after again proving Invitation credentials if necessary. The callback uses only Assent's normalized `sub` as the provider subject and treats `preferred_username` and all other claims as mutable metadata.

On a successful callback, one short database transaction locks the Invitation, Attempt, and Continuation; rechecks all expiry and status fences; and changes the Continuation to `verified`. It also creates an **active Discord subject claim** for `(discord, sub)`. This claim is a transient uniqueness reservation owned by the Continuation, not an account link: it contains no Principal reference and confers no login capability. A database uniqueness constraint covers active claims by provider and provider subject. Creating the claim also checks for an existing `external_identities` row with the same pair. The callback returns the browser to the acceptance-resume route and does not call sign-in, create a Principal, or establish a Session.

The claim prevents two simultaneous acceptance flows from charging for, or eventually binding, the same Discord account. Every other route that can bind a Discord subject—including authenticated linking and the later existing-Member prefill activation—must consult this claim before binding and report that identity verification is in progress rather than bypass it. When final conversion deletes the claim and inserts the External Identity in one transaction, the external-identity uniqueness constraint becomes the permanent barrier. The binding and collision check never use Discord email, username, guild nickname, or avatar.

### Acceptance and payment ordering

The acceptance-resume command requires the browser-held, `verified` Continuation and locks the Invitation, Attempt, Continuation, and active subject claim. It consumes the browser's continuation handle into the Attempt, so a duplicate resume request cannot start a second payment progression. It is the point at which verified Invitation credentials and verified Discord subject become durable input to the Attempt.

Only after that command has succeeded may the Attempt begin Stripe work. The Attempt records each outbound step before it occurs and uses its existing stable Stripe idempotency keys on every retry, as ADR-0013 requires. Thus a Discord OAuth error or a known Discord collision never creates Stripe state. A Stripe transport or provider-progress failure leaves the Attempt, verified Continuation, and subject claim in place for its normal retry/reconciliation path; it does not re-run OAuth or create another claim.

Beginning the Attempt before the Invitation's `expires_at` establishes an expiry fence for that Attempt only. The normal expiry process may expire a pending Invitation with no active Attempt, but must not expire one whose verified Continuation has been consumed into an active Attempt. This permits an already-authorized payment retry to finish after the wall-clock Invitation expiry without reopening Invitation credentials or accepting a new claimant. If the Attempt is declined, cancelled, or reaches a terminal unrecoverable payment failure, it releases its claim and closes. A new Attempt is allowed only while the Invitation has not expired; once the normal deadline has passed, no new credential verification, Continuation, or Attempt may begin.

After Stripe progression has reached the point defined by ADR-0013 as ready to finalize, finalization runs one database transaction that locks the same Invitation, Attempt, Continuation, and claim and creates all of the following together:

1. the pre-allocated Authentication Principal with the Invitation email;
2. the claimed-or-new UserProfile and MemberProfile;
3. the `member` Role;
4. the Stripe-backed Membership (including the existing 100% discount path for complimentary membership);
5. the accepted Invitation and joined Waitlist transition; and
6. the Discord External Identity with `(provider: discord, provider_subject: continuation.sub)` and current username metadata.

That transaction deletes the transient subject claim and marks the Continuation consumed. It creates neither a Phoenix authenticated Session nor a magic link. The success response directs the new Member to normal sign-in; magic-link login remains available.

### Replay, retries, and collision outcomes

All transitions are compare-and-set under the relevant row locks and are idempotent by their durable identities:

| Event | Required outcome |
| --- | --- |
| Duplicate credential verification | Resume the one active Attempt; never create another active Attempt. A live Continuation is returned only to its existing protected browser session; otherwise create a replacement only after the previous one has ended or expired. |
| Duplicate OAuth callback | The first valid callback may change `awaiting_oauth` to `verified`. A repeat for that state returns the already-verified continuation without a second claim or redirecting to sign-in. A callback after consumption, expiry, cancellation, or failed state is rejected. |
| Duplicate acceptance-resume request | The first request consumes the verified continuation into the Attempt. Later requests observe the same Attempt and return its current safe status; they do not repeat a Stripe call. |
| Stripe retry or reconciliation | Resume the same Attempt, continuation, claim, and provider idempotency keys. Do not require fresh Discord OAuth while the Attempt remains active. |
| Finalization retry after local rollback | Resume the same Attempt. Re-run the atomic finalization only when its Stripe progress permits; never create a partial Principal or External Identity. |
| Finalization after commit | Return the accepted Invitation/Attempt outcome. Do not create a Session, additional Membership, Role, or External Identity. |

If the callback finds an existing External Identity for the Discord subject, or cannot acquire the active subject claim, it marks the Continuation `collision`, records a support-safe audit event with the existing Principal reference when one exists and a keyed subject fingerprint otherwise, and releases no existing link. It must not disclose the matched Member, email, or Principal to the prospective Member. The Attempt closes without Stripe work. The public response is a neutral "this Discord account cannot be used for this invitation" outcome and directs the person to club support. Support resolves an actual wrong link or administrator assignment through the separately defined authenticated recovery/correction process; it never fixes a collision by matching Discord email or username. A collision after Stripe work is prevented by the claim barrier; an unexpected database uniqueness conflict during finalization is treated as a reconciliation incident, leaves the Attempt durable, and must not silently bind an account or mint a Session.

Expired, cancelled, collision, and terminally failed Continuations zeroize their raw Discord subject and display metadata and release their active claim. They retain only lifecycle timestamps, reason, Attempt/Invitation references, and the keyed subject fingerprint necessary for audit and abuse investigation. Consumed Continuations likewise retain audit state but are not a second identity store. Therefore the only enduring association from a Discord subject to a Principal is the External Identity inserted by the final conversion transaction.

## Consequences

- The continuation is durable enough for an OAuth redirect, payment retries, and recovery, while protected browser session state remains only a delivery mechanism and never becomes an authenticated DHC Session.
- A Discord account is verified before Stripe can create external state, and no Discord account link exists until the all-or-nothing Principal-and-Member conversion commits.
- The active subject claim is required infrastructure for every Discord binding path. It is deliberately transient and privacy-minimized, not a pending Principal or an alternate External Identity lifecycle.
- Implementers must test the expiry fence, browser-session loss, callback and resume replay, concurrent same-subject acceptance, collision without information disclosure, Stripe retry after OAuth, finalization rollback, and the assertion that no callback or acceptance response creates a Session.

## Considered options

- **A signed callback-to-acceptance assertion.** Rejected because a bearer artifact would need its own replay and cross-invitation protections, is easy to leak through URLs or browser storage, and does not give the durable Attempt enough recovery state for payment retries.
- **Create the External Identity at the OAuth callback.** Rejected because it creates an identity without its Principal if payment or final conversion fails, violating the atomic acceptance invariant.
- **Run Stripe before Discord OAuth.** Rejected because an account collision would leave avoidable external payment state and force compensation before DHC can create the Member.
- **Rely only on `external_identities` uniqueness at finalization.** Rejected because two unlinked acceptances could both pass preflight and reach Stripe before one loses the final insert race.
