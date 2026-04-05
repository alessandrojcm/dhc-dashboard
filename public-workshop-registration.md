# Public Workshop Registration Plan

## Scope Decisions

- **External registrant phone number**: optional
- **Abuse/rate limiting**: deferred to a follow-up
- **Confirmation emails**: deferred to a follow-up

## Goal

Enable external (non-authenticated) users to register and pay for public workshops via a public route, while keeping the existing member registration flow and interfaces backward-compatible.

## Constraints and Current Reality

- Existing member flow lives under `src/routes/dashboard/my-workshops/` and uses `RegistrationService`.
- `RegistrationService` currently assumes member session usage in key methods (e.g. `session.user.id`).
- DB already supports external registration:
  - `club_activity_registrations` has both `member_user_id` and `external_user_id`
  - `external_users` table exists
  - check constraint enforces one actor type per registration
- Public scaffold exists at `src/routes/(public)/workshops/[id]/register/` (currently empty).

## Core Design Direction

1. Keep existing member-facing interfaces unchanged.
2. Add explicit public/external registration entry points in the service layer.
3. Use a system/service auth context for RLS execution in public routes (session-like context backed by service role JWT), without changing existing member caller contracts.
4. Derive external pricing server-side from workshop data (never trust client amount).

---

## Stage 1 — Service auth context + non-breaking entry points (serial)

### Objective
Support external/public flows without breaking existing member code paths.

### Deliverables

- Keep `createRegistrationService(platform, session, ...)` unchanged.
- Add a public/system factory (e.g. `createPublicRegistrationService(platform, ...)`) that supplies a service-role-backed session-like auth context internally.
- Refactor internals to prevent external methods from depending on `session.user.id`.

### Stage 1A — Auth model we will introduce

`RegistrationService` will stop treating constructor `session` as both:

1. RLS claims source
2. actor identity source

Instead, we split these concerns conceptually:

- **RLS claims context**: only needed for `executeWithRLS(..., { claims })`
- **Actor context**: who is performing the operation (`member` vs `system`)

Proposed internal shape:

```ts
type RegistrationActor =
  | { kind: "member"; memberUserId: string }
  | { kind: "system" };
```

This lets us keep member methods unchanged externally while making external/public methods independent from `session.user.id`.

### Stage 1B — Factory design (non-breaking)

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

- Creates `RegistrationService` with actor context `{ kind: "system" }`.
- Uses service-role JWT as claims for `executeWithRLS`.
- Supports optional override in tests (e.g. `opts.claimsSession`) to avoid hard-coupling tests to runtime env.

Implementation note:

- Add a helper like `buildServiceRoleSession()` in service/shared layer.
- It should construct a valid session-like object from `SERVICE_ROLE_KEY` (or throw clearly if missing).
- This helper is only for server-side internal service usage.

### Stage 1C — How we replace session-derived identity

We do **not** use `session.user.id` as identity in external/public flow.

Identity source by flow:

- **Member flow**: `memberUserId` comes from actor context (initialized from authenticated session in existing factory).
- **External flow**: identity comes from explicit input (`firstName`, `lastName`, `email`, optional `phone`) and DB `external_users.id` linkage.
- **System/public execution**: uses service-role claims for DB execution authority, but actor kind remains `system`.

### Stage 1D — Internal refactor checklist

1. Add private helper for member-only identity:

```ts
private requireMemberUserId(context: string): string
```

- Throws with clear error if called under `system` actor.

2. Replace all direct `this.session.user.id` reads in `RegistrationService` with:

- `const memberUserId = this.requireMemberUserId("...")` for member-only methods.

3. Keep DB transaction pattern unchanged:

- `executeWithRLS(this.kysely, { claims: this.session }, ...)` remains the execution wrapper.

4. Prepare shared helper methods for Stage 2 (so new external methods can reuse logic without member-session assumptions):

- workshop lookup + publish/public checks
- capacity check
- duplicate registration check by actor type

5. Logging update:

- Log actor kind (`member`/`system`) instead of always logging `userId`.

### Stage 1E — Compatibility guarantees

- No route-level signature changes required for existing dashboard member registration.
- Existing `.remote.ts` member flows continue to call `createRegistrationService(platform, session)`.
- New public routes use `createPublicRegistrationService(platform, ...)`.
- Existing member method signatures (`createPaymentIntent`, `completeRegistration`, etc.) remain unchanged during Stage 1.

### Notes

- Preserve compatibility with all existing dashboard and remote function callers.
- Keep all DB mutations inside service methods.

---

## Stage 2 — External registration methods in `RegistrationService` (serial)

### Objective
Implement explicit external flow logic (payment intent + completion).

### Deliverables

- Add external-specific service methods:
  - `createExternalPaymentIntent(...)`
  - `completeExternalRegistration(...)`
- Introduce shared validation helpers for:
  - workshop existence
  - workshop `status = published`
  - workshop `is_public = true` (for external flow)
  - capacity checks
  - duplicate registration checks
- Enforce **server-derived external amount** from `price_non_member`.
- Stripe metadata must encode actor type and workshop id for safe completion validation.

### Stage 2A — Payment intent contract (external flow)

We will use a **Payment Intent + Payment Element** flow (not Checkout Session).

Proposed service input:

```ts
type CreateExternalPaymentIntentInput = {
  workshopId: string;
  externalUser: {
    firstName: string;
    lastName: string;
    email: string;
    phoneNumber?: string | null;
  };
  currency?: string; // defaults to workshop currency / "eur"
};
```

What data we need to create the Payment Intent:

1. `workshopId`
2. workshop title/status/public flag/max capacity
3. workshop external price (`price_non_member`) as the source of truth
4. canonical external identity (normalized email + resolved `external_user_id`)
5. currency (server default if omitted)

What the server returns:

```ts
type CreateExternalPaymentIntentResult = {
  clientSecret: string;
  paymentIntentId: string;
  amount: number;   // server-derived cents
  currency: string;
};
```

Client **must not send amount** for external flow.

### Stage 2B — Stripe integration and checkout type

- We will integrate with **Stripe Elements (Payment Element)**, consistent with the current member checkout component pattern.
- Confirmation path uses `stripe.confirmPayment({ elements, redirect: "if_required" })` and then calls `completeExternalRegistration(...)`.
- We are **not** introducing Stripe Checkout Session in this stage.
- Metadata to include on Payment Intent (minimum):
  - `type = workshop_registration`
  - `actor_type = external`
  - `workshop_id`
  - `external_user_id`
  - `external_email_normalized`

Note: DB column name is currently `stripe_checkout_session_id`; in current code it stores Payment Intent IDs. We keep this behavior for compatibility in this phase.

### Stage 2C — Capacity checks (expanded)

We apply capacity validation in **two places**:

1. **Pre-intent soft check** in `createExternalPaymentIntent(...)`
   - fast reject if already full (count `pending` + `confirmed` against `max_capacity`)
2. **Completion hard check** in `completeExternalRegistration(...)`
   - inside transaction, re-check capacity immediately before insert
   - this is the authoritative gate

Implementation guidance for hard check:

- Lock workshop row (`FOR UPDATE`) (if kysely allows, check docs) before counting/inserting to reduce race overbooking.
- Treat `pending` + `confirmed` as occupied seats.
- If full at completion, return a deterministic domain error (`WORKSHOP_FULL`).

Important: payment intent creation does **not** reserve a seat. The completion check is what guarantees final seat allocation.

### Stage 2D — Duplicate checks (expanded)

There are two duplicate layers:

1. **Identity-level dedupe** in `external_users`
   - `external_users.email` is unique
   - we will normalize email (`trim().toLowerCase()`) before lookup/upsert
2. **Registration-level dedupe** in `club_activity_registrations`
   - `UNIQUE (club_activity_id, external_user_id)` already exists
   - service pre-check for `status IN ('pending','confirmed')`
   - DB unique constraint remains final race-safe guard

### Stage 2E — External identity clashes and insert-vs-update rules

`external_users` has no auth user FK by design. For external flow, **email is the identity key**.

Rules:

- If normalized email does not exist: **INSERT** new `external_users` row.
- If normalized email exists: **UPDATE** profile fields (name/phone) and reuse existing `external_user_id`.
- Then create registration row tied to that `external_user_id`.

Consequences:

- Same external person can register for multiple workshops (allowed), because uniqueness is per `(workshop, external_user)`.
- Same email cannot register twice for the same workshop (blocked by service + DB constraint).
- If two different people share an email address, system will treat them as one external identity (acceptable constraint for unauthenticated flow; document in UX copy).

### Stage 2F — Completion idempotency and duplicate retries

`completeExternalRegistration(...)` should be retry-safe:

- If a registration already exists for `(workshop_id, external_user_id)` with `status = confirmed`, return existing row (idempotent success).
- If payment intent metadata does not match input workshop/external user, reject.
- If duplicate insert race occurs (unique violation), fetch existing row and return it when compatible.

### Stage 2G — Registration lifecycle rule (insert vs update) + email normalization

Because `club_activity_registrations` has `UNIQUE (club_activity_id, external_user_id)`, we cannot create multiple rows for the same external user/workshop pair.

Decisions for Stage 2:

1. **External identity normalization**
   - Always canonicalize email before dedupe/upsert:
     - trim whitespace
     - lowercase
   - Follow-up migration recommended: enforce case-insensitive uniqueness (e.g. `UNIQUE (lower(email))` or `citext`) to align DB with service behavior.

2. **Registration row behavior**
   - First-time registration for workshop + external user: **INSERT**.
   - Retry/duplicate completion for same successful payment: **return existing** row (idempotent success).
   - If a row already exists in `pending` or `confirmed`: treat as duplicate (or idempotent success if same payment intent).
   - If a row exists in `cancelled` or `refunded` and re-registration is allowed, do **UPDATE lifecycle reset** on the same row (`status`, payment fields, timestamps) instead of insert.

3. **Same external user across different workshops**
   - Allowed: one `external_users` identity can be linked to many workshop registrations.
   - Constraint only blocks duplicates per workshop, not across workshops.

### Safety Requirements

- Idempotent completion behavior (retry-safe for duplicate callback/submission).
- Reject mismatched payment metadata.

---

## Stage 3 — Public route backend surface (serial)

### Objective
Expose public registration/payment handlers using service layer only.

### Deliverables

- Implement:
  - `src/routes/(public)/workshops/[id]/register/+page.server.ts`
  - `src/routes/(public)/workshops/[id]/register/data.remote.ts` (or equivalent remote file)
- Public handlers should:
  - load workshop + gating state
  - create external payment intent
  - complete external registration
- Gating rule: only allow when workshop is both `published` and `is_public = true`.

### Response Conventions

- Success shape: `{ success: true, ... }`
- Error shape: `{ success: false, error: string }`

---

## Stage 4 — Public UI payment flow (serial after Stage 3 contracts)

### Objective
Provide a complete external registration UI at `/workshops/[id]/register` using a **one-step progressive form**.

### Deliverables

- Build a single-page form layout:
  1. **Top:** workshop summary (title/date/location/price)
  2. **Middle:** external user details
     - first name (required)
     - last name (required)
     - email (required)
     - phone (optional)
  3. **Bottom:** Stripe payment area (progressively enabled)
- Integrate Stripe Payment Element in the same page (no separate step/screen).
- Handle success redirect to existing confirmation route:
  - `src/routes/(public)/workshops/[id]/confirmation/+page.svelte`
- Clear UX for common failures:
  - full capacity
  - already registered
  - payment failure

### Stage 4A — One-step progressive interaction model

This is still one visual form, but with progressive activation:

1. User enters contact details.
2. Once details are valid, create external payment intent.
3. Mount Payment Element inline.
4. User confirms payment.
5. Call registration completion and redirect.

This keeps UX simple while preserving server-side authority for pricing and registration checks.

### Stage 4B — Stripe loading timing (one-step flow)

We will follow existing project patterns (`payment-form.svelte`, `workshop-express-checkout.svelte`):

1. **On mount:** load Stripe.js (`loadStripe(PUBLIC_STRIPE_KEY)`).
2. **Do not** create Elements immediately.
3. Create payment intent only when details are valid.
4. After server returns `clientSecret`, create `elements(...)` and mount Payment Element.
5. If identity fields change after intent creation, invalidate payment section and regenerate intent (unmount + recreate) before allowing submit.

Implementation guardrails:

- Prevent intent spam while typing (debounce + in-flight lock).
- Track a normalized identity signature (`firstName|lastName|email|phone|workshopId`) and only recreate intent when signature changes.
- Keep a deterministic loading/error state for payment area.

### Stage 4C — Svelte form compatibility

Yes, this flow is compatible with Svelte remote forms.

- Keep one visual `<form>`.
- Use normal field-level validation/errors for contact inputs.
- Use async side effect (remote command/mutation) to create intent when form becomes valid.
- On submit:
  - `stripe.confirmPayment({ elements, redirect: "if_required" })`
  - then call `completeExternalRegistration(...)`
  - then redirect to confirmation route.

### Stage 4D — Route/layout-level gating checks

Before rendering payment-capable UI, page load must validate:

1. workshop exists
2. workshop status is `published`
3. workshop `is_public = true`
4. optional soft capacity check for UX messaging

Return load flags (example):

```ts
{
  canRegister: boolean,
  gateReason?: "NOT_FOUND" | "NOT_PUBLISHED" | "NOT_PUBLIC" | "FULL",
  workshop: {...displayData}
}
```

UI rule: if `canRegister` is false, render gated informational state and do not mount Stripe.

### Stage 4E — UI state model

Use an explicit state machine for predictability and race-safety in the one-step flow.

States:

- `idle`: user edits details; payment section not ready
- `intent_loading`: creating/recreating external payment intent
- `intent_ready`: client secret is current; Payment Element mounted
- `confirming_payment`: running Stripe confirmation
- `completing_registration`: persisting registration after successful payment
- `success`: terminal success; redirect to confirmation page
- `error`: recoverable failure state with typed source/reason

Operational rules:

1. **Single in-flight transition**
   - Only one async action should run at a time for intent creation/confirmation/completion.
   - Prevent duplicate click/double-submit transitions.

2. **Identity signature drives intent freshness**
   - Track normalized signature: `firstName|lastName|email|phone|workshopId`.
   - Reuse current intent only when signature matches.
   - If signature changes after intent is ready, invalidate payment section and regenerate intent.

3. **Intent creation guardrails**
   - Debounce while typing to avoid excessive intent creation.
   - Ignore stale async responses that do not match the latest requested signature.

4. **Payment/submit gate**
   - Allow pay action only in `intent_ready`.
   - While `confirming_payment` or `completing_registration`, keep actions locked.

5. **Idempotent recovery**
   - Retries from `error` are allowed and should route to the correct prior step.
   - Completion retries remain safe because Stage 2 completion behavior is idempotent.

#### State transition table

| Current state | Event / condition | Next state | Notes |
|---|---|---|---|
| `idle` | Details invalid or incomplete | `idle` | Keep payment section disabled/unmounted |
| `idle` | Details become valid | `intent_loading` | Start debounced create-intent request |
| `intent_loading` | Intent created for latest signature | `intent_ready` | Mount Payment Element with returned client secret |
| `intent_loading` | Intent request fails | `error` | Store typed error source = `intent` |
| `intent_loading` | User changes details before response | `intent_loading` (latest only) | Older responses are ignored as stale |
| `intent_ready` | User edits identity fields | `intent_loading` (or `idle` until valid) | Invalidate/unmount current payment element and regenerate intent |
| `intent_ready` | User clicks Pay | `confirming_payment` | Lock UI actions |
| `confirming_payment` | Stripe returns confirmation error | `error` | Error source = `payment` |
| `confirming_payment` | Stripe confirms payment | `completing_registration` | Continue with backend completion call |
| `completing_registration` | Completion succeeds (or idempotent compatible duplicate) | `success` | Redirect to confirmation route |
| `completing_registration` | Domain/business failure (e.g. full) | `error` | Error source = `completion`; show mapped message |
| `error` | User retries setup | `intent_loading` | Recreate intent for latest valid signature |
| `error` | User retries pay with valid mounted element | `confirming_payment` | Only when intent is still current and ready |

Error mapping for user-facing messages:

- `WORKSHOP_FULL` → workshop full message
- `ALREADY_REGISTERED` → already registered message
- Stripe confirmation errors → payment failed message
- Unknown errors → generic retry guidance

---

## Stage 5 — Tests (service + route + focused E2E)

### Objective
Cover critical behavior with pragmatic depth.

### Stage 5A — Test process sanity checks (pre-flight)

Before running this stage, verify:

1. Local services are running (in order):

```bash
pnpm supabase:start
pnpm supabase:functions:serve
pnpm dev
```

2. Test data is unique per run (timestamp + random suffix where needed).
3. Public registration tests do **not** introduce deprecated `/api/workshops/*` test transport patterns.
4. Assertions follow existing E2E stability patterns from `e2e/workshops-ui.spec.ts`:
   - use role-based selectors
   - for workshop detail assertions, click calendar event first and scope checks to dialog
5. Keep service and route tests deterministic (no real Stripe network side effects in unit/service tests unless explicitly marked integration).

### Stage 5B — Service tests (expanded)

Test `RegistrationService` external methods directly with explicit fixtures.

Core cases:

1. **External happy path**
   - `createExternalPaymentIntent(...)` returns `clientSecret`, `paymentIntentId`, server-derived `amount`, `currency`.
   - `completeExternalRegistration(...)` creates confirmed registration with `external_user_id` set and `member_user_id = null`.

2. **Gating and eligibility**
   - reject workshop not found
   - reject `status != published`
   - reject `is_public = false`

3. **Capacity behavior**
   - soft reject when full at intent step
   - hard reject at completion when capacity is consumed between intent and completion (`WORKSHOP_FULL`)

4. **Duplicate behavior**
   - reject duplicate when existing pending/confirmed registration exists for same `(workshop, external_user)`
   - idempotent success when retrying compatible completion for same payment intent

5. **Metadata safety**
   - reject payment intent whose metadata actor/workshop/external identity does not match completion input

6. **Identity normalization**
   - email normalization (`trim().toLowerCase()`) reuses same `external_users` row
   - completion is still scoped by normalized identity

### Stage 5C — Route tests (expanded)

Cover `+page.server.ts` and `data.remote.ts` contracts for the public route.

`+page.server.ts` load cases:

- workshop not found → `canRegister: false`, `gateReason: "NOT_FOUND"`
- workshop planned/unpublished → `canRegister: false`, `gateReason: "NOT_PUBLISHED"`
- workshop non-public → `canRegister: false`, `gateReason: "NOT_PUBLIC"`
- workshop eligible → `canRegister: true` and expected display payload

Remote action cases:

- create intent success shape: `{ success: true, clientSecret, paymentIntentId, amount, currency }`
- create intent failure shape: `{ success: false, error }`
- completion success shape: `{ success: true, registration }` (or agreed payload)
- completion failure shape: `{ success: false, error }`

### Stage 5D — Focused E2E cases (expanded)

Start with a minimal but representative matrix:

1. **Happy path (external registrant)**
   - open `/workshops/[id]/register` for published public workshop
   - enter valid identity data
   - confirm payment
   - redirect to `/workshops/[id]/confirmation`
   - confirmation shows expected workshop/registrant summary

2. **Failure path (business rule)**
   - complete flow until completion step
   - simulate/seed workshop becoming full before final completion
   - verify user sees full-capacity error and no duplicate/phantom success redirect

Optional third case if time permits:

3. **Duplicate retry / already-registered UX**
   - second attempt with same normalized email/workshop
   - assert mapped `ALREADY_REGISTERED` message

### Stage 5E — Tear-up and teardown strategy

Use the same test hygiene patterns already used in `e2e/workshops-ui.spec.ts`, but tighten cleanup discipline.

#### Tear-up (test setup)

- In `beforeAll`:
  - create stable role-based fixtures (e.g. admin/coordinator) via `createMember(...)`
  - store returned fixture handles (`email`, `userId`, `cleanUp`)
- Per test:
  - create workshop fixtures with `createWorkshop(...)` and unique titles
  - login with `loginAsUser(context, email)` where auth is needed

#### Teardown (cleanup)

- In `afterEach` or `afterAll`:
  - execute collected cleanup functions from `createMember`/`createWorkshop`
  - prefer `Promise.allSettled(cleanups)` for best-effort cleanup so one failure does not hide others
- Keep global baseline reset in `e2e/global-setup.ts` as safety net, but do **not** rely on it as the only cleanup layer.

Suggested cleanup pattern:

```ts
const cleanups: Array<() => Promise<unknown>> = [];

test.beforeAll(async () => {
  const admin = await createMember({ email: `admin-${Date.now()}@test.com`, roles: new Set(["admin"]) });
  cleanups.push(admin.cleanUp);
});

test.afterAll(async () => {
  await Promise.allSettled(cleanups.map((fn) => fn()));
});
```

This keeps E2E runs reproducible and prevents fixture leakage across runs.

---

## Explicitly Deferred

- External confirmation email sending
- Public-route abuse protections (rate limits, bot mitigation)

These will be handled in a follow-up implementation phase.
