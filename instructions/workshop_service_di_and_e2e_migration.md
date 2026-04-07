# Workshop Service DI and E2E Migration

## Goal

Make workshop-related service classes portable by removing their transitive runtime dependence on SvelteKit `$env` via the shared Stripe client, then migrate workshop E2E tests away from deprecated `/api/workshops/*` usage toward direct service-backed setup/helpers.

## Constraints

- Do not change product behavior
- Do not change test assumptions, only setup/transport where needed
- Keep runtime awareness in service factories, not in service classes
- Keep using a real Stripe test client in E2E, matching current test strategy

## Architectural Decisions

1. **Service constructors require Stripe when Stripe is used**
   - Stripe-coupled classes should receive Stripe explicitly in their constructors
   - This keeps the classes portable and independent of `$env/dynamic/private`

2. **Factories remain runtime-aware**
   - Factory functions can keep using `platform.env.HYPERDRIVE`
   - Factories should provide the real runtime Stripe client by default
   - Factories may accept an optional Stripe override for test/tooling flexibility

3. **Playwright helpers should instantiate service classes directly**
   - For E2E setup/helpers, bypass factory `index.ts` files when convenient
   - Provide Kysely/session/logger/Stripe explicitly
   - This avoids SvelteKit runtime-only imports in Playwright helper code

4. **Use a real Stripe client in tests**
   - Follow existing E2E practice
   - Do not introduce `vi.mock`-style assumptions into Playwright

## Why this refactor is needed

The service classes themselves mostly do not use `$env`, `process`, `platform`, or `import.meta.env` directly. The problem is narrower:

- some services import `stripeClient` from `$lib/server/stripe`
- `$lib/server/stripe` imports `$env/dynamic/private`
- Playwright Node-side helpers cannot use `vi.mock(...)`
- Playwright does not provide a Node module mocking API equivalent to Vitest

So the clean fix is dependency injection, not runtime mocking.

---

## File-by-file implementation instructions

### 1) `src/lib/server/services/workshops/workshop.service.ts`

#### Changes
- Remove direct import of `stripeClient` from `$lib/server/stripe`
- Add a required Stripe client dependency to the `WorkshopService` constructor
- Store that dependency on the class and use it in `cancel()` instead of the imported singleton

#### Notes
- `publish()` itself is not Stripe-backed, but `cancel()` is
- Keep the class portable; no direct runtime/env imports should remain here

#### Acceptance criteria
- No `$lib/server/stripe` import remains in this file
- `cancel()` uses injected Stripe client
- Typecheck catches all updated constructor callsites

---

### 2) `src/lib/server/services/workshops/registration.service.ts`

#### Changes
- Remove direct import of `stripeClient` from `$lib/server/stripe`
- Add a required Stripe client dependency to the `RegistrationService` constructor
- Use the injected Stripe client in payment intent / payment confirmation paths

#### Notes
- Even methods like `toggleInterest()` do not need Stripe, but constructor-level DI keeps the class shape consistent
- This is acceptable because factories will hide runtime wiring for app code

#### Acceptance criteria
- No `$lib/server/stripe` import remains in this file
- All Stripe usage goes through the injected dependency

---

### 3) `src/lib/server/services/workshops/refund.service.ts`

#### Changes
- Remove direct import of `stripeClient` from `$lib/server/stripe`
- Add a required Stripe client dependency to the `RefundService` constructor
- Use injected Stripe client in `processRefund()` / `_processRefund()`

#### Notes
- This file is one of the main blockers for Playwright portability
- Keep refund eligibility logic unchanged

#### Acceptance criteria
- No `$lib/server/stripe` import remains in this file
- Refund logic still behaves identically, but with injected Stripe

---

### 4) `src/lib/server/services/invitations/pricing.service.ts`

#### Changes
- Apply the same constructor injection pattern
- Remove direct `$lib/server/stripe` import
- Use injected Stripe client for invoice/coupon operations

#### Notes
- This is outside workshops, but small enough to include now for consistency

#### Acceptance criteria
- No `$lib/server/stripe` import remains in this file
- Pricing service follows the same portability rule as workshop Stripe-coupled services

---

### 5) `src/lib/server/services/workshops/index.ts`

#### Changes
- Keep `platform.env.HYPERDRIVE` wiring here
- Import the real runtime `stripeClient` here instead of inside service classes
- Update `createWorkshopService`, `createRefundService`, and `createRegistrationService` to pass the real Stripe client by default
- Optionally allow a Stripe override param for tests/tooling

#### Notes
- This file should remain runtime-aware
- This file is the right place for SvelteKit/runtime coupling

#### Acceptance criteria
- App/runtime callsites can keep using factories
- Factories compile after constructor changes
- Service classes remain runtime-agnostic

---

### 6) `src/lib/server/services/invitations/index.ts`

#### Changes
- If `pricing.service.ts` is instantiated via factory here, update it to pass the real Stripe client
- Optionally support Stripe override param for consistency with workshops

#### Acceptance criteria
- Invitations pricing factory matches the new constructor signature

---

### 7) `e2e/setupFunctions.ts`

#### Changes
- Reuse the existing real Stripe client already created from `process.env`
- If needed, add a small helper to create service instances for Playwright-side setup code
- Keep env loading via `dotenv/config`

#### Notes
- This file already has the right pattern for Playwright-side real env access
- Prefer centralizing helper wiring here or in `attendee-test-helpers.ts`

#### Acceptance criteria
- Playwright setup code has access to a real Stripe test client without importing SvelteKit `$env` modules

---

### 8) `e2e/attendee-test-helpers.ts`

#### Changes
- Replace deprecated `/api/workshops/*` helper calls with direct service-backed helper calls where appropriate
- Add helper(s) to instantiate the needed workshop services directly using:
  - Kysely client
  - session
  - logger
  - real Stripe client
- Keep raw DB seeding helpers where there is no better service path or where Stripe-free seeding is simpler

#### Specific deprecated usages to replace
- refund creation helper
- attendance update helper
- attendance fetch helper
- refund fetch helper
- any publish/interest helper if centralized here

#### Special case
- If a helper still depends on missing product behavior such as a workshop `finish` action, prefer a deterministic DB/service-compatible setup path instead of introducing a new product remote function just for tests

#### Acceptance criteria
- No deprecated `/api/workshops/*` helper usage remains here
- Helper API remains easy for specs to consume

---

### 9) `e2e/workshop-full-lifecycle.spec.ts`

#### Changes
- Replace deprecated refund and attendance API calls with helper/service-backed calls
- Keep scenario and assertions the same

#### Acceptance criteria
- Test still verifies the full lifecycle assumptions
- No `/api/workshops/*` transport usage remains

---

### 10) `e2e/refund-management.spec.ts`

#### Changes
- Replace refund API calls with service-backed helpers/direct service usage
- Preserve validation/error expectations as closely as possible

#### Notes
- If the transport shape changes, adapt only the assertion wrapper shape, not the business expectation

#### Acceptance criteria
- Refund scenarios remain intact
- No deprecated `/api/workshops/*` calls remain

---

### 11) `e2e/attendance-management.spec.ts`

#### Changes
- Replace attendance GET/PUT API calls with direct service-backed helper calls
- Preserve validation coverage and attendance assertions

#### Acceptance criteria
- No deprecated `/api/workshops/*` calls remain
- Attendance scenarios still cover the same business rules

---

### 12) `e2e/workshops-interest.spec.ts`

#### Changes
- Replace deprecated interest/publish API calls with service-backed helper calls where used for setup or direct action triggering
- Keep UI assertions/UI-driven parts intact

#### Acceptance criteria
- Interest tests preserve semantics
- No deprecated `/api/workshops/*` usage remains

---

### 13) `e2e/my-workshops.spec.ts`

#### Changes
- Replace any remaining deprecated workshop interest API usage with service-backed helper calls

#### Acceptance criteria
- No deprecated workshop API usage remains in this file

---

## Validation checklist

### Required
- Run `pnpm check`
- Run the affected workshop E2E specs or the relevant workshop subset

### Verify specifically
- service classes can be imported in Playwright helper code without SvelteKit `$env` resolution failures
- runtime app code still works through the service factories
- Stripe-backed workshop flows still use the real Stripe test client
- migrated tests keep the same scenario assumptions

## Expected outcome

After this refactor:

- service classes are portable and test-friendly
- runtime/env coupling stays in factory wiring
- Playwright helpers can use service classes directly
- workshop E2E tests stop relying on deprecated `/api/workshops/*` paths
