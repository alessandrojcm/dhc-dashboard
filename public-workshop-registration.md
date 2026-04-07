# Public Workshop Registration Plan

## Scope Decisions

- **External registrant phone number**: optional
- **Abuse/rate limiting**: deferred to a follow-up
- **Confirmation emails**: deferred to a follow-up

## Goal

Enable external (non-authenticated) users to register and pay for public workshops via a public route, while keeping the existing member registration flow backward-compatible.

## Constraints and Current Reality

- Existing member flow lives under `src/routes/dashboard/my-workshops/` and uses `RegistrationService`.
- DB already supports external registration:
  - `club_activity_registrations` has both `member_user_id` and `external_user_id`
  - `external_users` table exists
  - check constraint enforces one actor type per registration
- Public routes exist under `src/routes/(public)/workshops/[id]/`.

## Core Design Direction

1. Keep existing member-facing interfaces unchanged.
2. Add explicit public/external registration entry points in the service layer.
3. Use a system/service auth context for RLS execution in public routes (session-like context backed by service role JWT).
4. Move external payment to **Stripe Checkout Session** (hosted/embedded compatible backend contract), not PaymentIntent + inline confirmation.
5. Complete registration by verifying Checkout Session server-side on confirmation return (optionally mirrored by webhook).

---

## Stage 1 — Service auth context + non-breaking entry points (serial)

### Objective

Support external/public flows without breaking existing member code paths.

### Deliverables

- Keep `createRegistrationService(platform, session, ...)` unchanged.
- Add public/system factory `createPublicRegistrationService(platform, ...)` that supplies service-role-backed claims.
- Refactor internals so external methods do not depend on `session.user.id`.

### Stage 1A — Auth model

`RegistrationService` should treat constructor inputs as:

- **RLS claims context** (for `executeWithRLS`)
- **Actor context** (`member` vs `system`)

```ts
type RegistrationActor =
  | { kind: "member"; memberUserId: string }
  | { kind: "system" };
```

### Stage 1B — Factory design

#### Existing factory (unchanged signature)

```ts
createRegistrationService(platform, session, stripe?, logger?)
```

- Keeps all current callers working.
- Builds actor context as `{ kind: "member", memberUserId: session.user.id }`.

#### New public/system factory

```ts
createPublicRegistrationService(platform, stripe?, logger?, opts?)
```

- Creates service with actor context `{ kind: "system" }`.
- Uses service-role JWT as claims for `executeWithRLS`.
- Supports optional claims override for tests.

### Stage 1C — Internal refactor checklist

1. Add private helper:

```ts
private requireMemberUserId(context: string): string
```

2. Replace direct `this.session.user.id` reads in member-only methods.
3. Keep `executeWithRLS(this.kysely, { claims: this.session }, ...)` unchanged.
4. Add/keep reusable helpers:
   - workshop eligibility lookup
   - capacity check
   - external user upsert
5. Logging should include actor kind (`member` / `system`).

### Stage 1D — Compatibility guarantees

- No route-level signature changes for existing dashboard member registration.
- Existing `.remote.ts` member flows continue using `createRegistrationService(platform, session)`.
- Public routes use `createPublicRegistrationService(platform)`.

---

## Stage 2 — External service methods with Checkout Session (serial)

### Objective

Implement external flow around **Stripe Checkout Session** and server-side completion.

### Deliverables

- Add external service methods:
  - `createExternalCheckoutSession(...)`
  - `completeExternalRegistrationFromCheckoutSession(...)`
- Remove legacy PaymentIntent-based external methods (now unneeded):
  - `createExternalPaymentIntent(...)`
  - `completeExternalRegistration(...)`
- Keep/extend shared validation helpers:
  - workshop existence / published / public / external price
  - capacity checks
  - external user upsert from Stripe customer details
- Enforce server-derived amount from `price_non_member`.
- Validate Stripe Checkout session data server-side before DB write.

### Stage 2A — Create Checkout Session contract

Proposed input:

```ts
type CreateExternalCheckoutSessionInput = {
  workshopId: string;
  successUrl: string; // must include ?session_id={CHECKOUT_SESSION_ID}
  cancelUrl: string;
};
```

Proposed result:

```ts
type CreateExternalCheckoutSessionResult = {
  checkoutSessionId: string;
  checkoutUrl: string;
};
```

Method behavior:

1. Validate workshop eligibility.
2. Soft capacity check (fast reject if full).
3. Create Stripe Checkout Session with server-derived amount.
4. Store metadata at minimum:
   - `type = workshop_registration`
   - `actor_type = external`
   - `workshop_id`

### Stage 2B — Complete from Checkout Session contract

Proposed input:

```ts
type CompleteExternalRegistrationFromCheckoutSessionInput = {
  workshopId: string;
  checkoutSessionId: string;
};
```

Method behavior:

1. Retrieve Checkout Session from Stripe by `checkoutSessionId`.
2. Verify payment status is complete/paid.
3. Verify metadata (`type`, `actor_type`, `workshop_id`) matches request.
4. Extract customer details from Stripe session (email/name/phone).
5. Upsert external user (email normalized).
6. Idempotency check by `stripe_checkout_session_id`.
7. Hard capacity check just before insert.
8. Insert confirmed registration (or return existing idempotent row).

### Stage 2C — Duplicate policy and idempotency

- We accept that duplicate attempts can occur pre-payment.
- Completion path must still be safe:
  - idempotent by `checkoutSessionId`
  - deterministic handling when an external user already has active registration for the same workshop
- Keep DB constraints as final race-safety boundary.

### Stage 2D — Security requirements

- Never trust query params alone; always retrieve Stripe session server-side.
- Never trust client amount/workshop; always derive from DB.
- Registration persistence only after successful Stripe verification.

---

## Stage 3 — Public route + UI Checkout flow (merged backend + frontend)

> This stage merges the previous “Stage 3 backend surface” and “Stage 4 UI payment flow”.

### Objective

Ship a simpler, deterministic public flow:

1. Open register page
2. Create Checkout Session on server
3. Redirect to Stripe Checkout
4. Return to confirmation route with `session_id`
5. Complete registration server-side from Stripe session

### Deliverables

- `src/routes/(public)/workshops/[id]/register/+page.server.ts`
- `src/routes/(public)/workshops/[id]/register/+page.svelte`
- `src/routes/(public)/workshops/[id]/register/data.remote.ts`
- `src/routes/(public)/workshops/[id]/confirmation/+page.server.ts`
- Keep `src/routes/(public)/workshops/[id]/confirmation/+page.svelte` as display page
- Route for full workshops: `src/routes/(public)/workshops/[id]/full/+page.svelte`

### Stage 3A — Load gating (`register/+page.server.ts`)

Load flow:

1. Validate `params.id` UUID.
2. Call `createPublicRegistrationService(platform).getExternalRegistrationGate(workshopId)`.
3. Apply route policy:

- `NOT_FOUND`, `NOT_PUBLISHED`, `NOT_PUBLIC`, `NO_EXTERNAL_PRICE` → `404`
- `FULL` → redirect to `/workshops/[id]/full`
- eligible → return workshop payload for summary UI

### Stage 3B — Register page UI (`register/+page.svelte`)

Simplified UI:

- Show workshop summary (title/date/location/price).
- Primary action: **Continue to payment**.
- Optional: lightweight pre-checkout fields for UX only (not required by checkout creation).
- No inline Stripe Payment Element state machine.

### Stage 3C — Create Checkout Session command (`register/data.remote.ts`)

Command:

- `createExternalCheckoutSession`

Rules:

1. Validate input with Valibot.
2. Enforce route/body workshop id match.
3. Construct `successUrl` with `{CHECKOUT_SESSION_ID}` placeholder and `cancelUrl` back to register page.
4. Call `createPublicRegistrationService(platform).createExternalCheckoutSession(input)`.
5. Success shape:
   - `{ success: true, checkoutUrl: string }`
6. Error shape:
   - `{ success: false, error: string, code?: string }`

Client behavior:

- On success, redirect browser to `checkoutUrl`.

### Stage 3D — Confirmation completion (`confirmation/+page.server.ts`)

Load flow:

1. Validate workshop id.
2. Read `session_id` from query params.
3. Call `createPublicRegistrationService(platform).completeExternalRegistrationFromCheckoutSession({ workshopId, checkoutSessionId: session_id })`.
4. Return confirmation payload (or throw deterministic error).

Success semantics:

- First completion creates registration.
- Re-load/retry is idempotent and returns existing registration.

### Stage 3E — Optional webhook reliability path

Optional but recommended:

- Add Stripe webhook endpoint listening to `checkout.session.completed`.
- Reuse same service completion method (or shared transactional helper).
- Keep idempotent behavior to tolerate both webhook and return-page completion.

### Response conventions

- Success: `{ success: true, ... }`
- Error: `{ success: false, error: string, code?: string }`

---

## Stage 4 — Tests (service + route + focused E2E)

### Objective

Cover critical behavior with pragmatic depth for the new Checkout-based flow.

### Stage 4A — Service tests

Core cases:

1. `createExternalCheckoutSession(...)` happy path:
   - returns `checkoutSessionId` and `checkoutUrl`
   - amount derived from workshop server-side
2. Eligibility failures:
   - not found / unpublished / non-public / missing external price
3. Capacity:
   - soft reject at session creation when full
   - hard reject at completion when seat is consumed before completion
4. Completion from session:
   - verifies Stripe session paid/complete
   - verifies metadata matches workshop
   - upserts external user from session customer details
   - creates confirmed registration
5. Idempotency:
   - repeated completion with same checkout session returns existing row

### Stage 4B — Route tests

`register/+page.server.ts`:

- unavailable states -> `404`
- full -> redirect `/workshops/[id]/full`
- eligible -> workshop payload

`register/data.remote.ts` command:

- success shape `{ success: true, checkoutUrl }`
- failure shape `{ success: false, error, code }`

`confirmation/+page.server.ts`:

- missing/invalid `session_id` handling
- valid paid session -> completion success
- invalid/unpaid/mismatched session -> deterministic failure

### Stage 4C — Focused E2E

1. Happy path:
   - open register page for eligible workshop
   - continue to Stripe Checkout
   - complete payment
   - return to confirmation page
2. Full path:
   - full workshop redirects to `/workshops/[id]/full`
3. Retry/idempotency:
   - re-open confirmation URL with same `session_id`
   - still shows success, no duplicate registration side effects

### Stage 4D — Test hygiene

- Keep unique fixture data per run.
- Keep cleanup with `Promise.allSettled`.
- Avoid deprecated `/api/workshops/*` transport usage in tests.

---

## Explicitly Deferred

- External confirmation email sending
- Public-route abuse protections (rate limits, bot mitigation)

These will be handled in a follow-up implementation phase.
