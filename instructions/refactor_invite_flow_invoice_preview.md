# Refactor Member Invitation & Subscription Flow using Stripe Invoice Preview API

---

## 1 Current Implementation (May 2025)

| Step | What happens                                                                                                                                                                                                                                                                          |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | `bulk_invite_with_subscription` Supabase Edge Function creates **Supabase user**, **Stripe customer**, and **two separate subscriptions** (`monthly`, `annual`) immediately. Each is created with `payment_behavior = "default_incomplete"`, generating two **PaymentIntents** (PIs). |
| 2    | IDs of both subscriptions + PIs are persisted in `payment_sessions` (with optional `coupon_id`).                                                                                                                                                                                      |
| 3    | An e-mail is sent to the invitee with a signup link (`/members/signup/[invitationId]`).                                                                                                                                                                                               |
| 4    | On the signup page the user fills personal data and **confirms** each PI via SEPA debit (mandate).                                                                                                                                                                                    |
| 5    | If the user never reaches this step < 24 h, Stripe auto-cancels the incomplete subscriptions → manual recovery required.                                                                                                                                                              |

Key features supported today: coupons, proration, credit-notes (post-invoice), real-time preview of amounts (hand-rolled in Svelte), optimistic DB updates, etc.

---

## 2 Stripe Invoice Preview API Overview

`GET /v1/invoices/upcoming` (or Stripe SDK `stripe.invoices.retrieveUpcoming`) can generate a _virtual_ invoice **without creating anything persistent**. It supports:

- `customer` **or** `customer_details` (so you can preview before the customer exists).
- `subscription_items` or `subscription_data[items]` → works with multiple items or entirely new subscriptions.
- `coupon`, `discounts`, `automatic_tax`, `subscription_data[billing_cycle_anchor]`, `proration_date`, etc.
- Returns `amount_due`, `lines`, tax, currency, etc.—exactly what will be charged if the request were executed for real.

Limitations / notes:

- A single API call previews **one invoice**. If you keep two separate subscriptions you will need **two previews** and aggregate totals yourself.
- **No payment happens**; you still need to create & confirm the subscriptions after the user accepts.

---

## 3 Feasibility Assessment

| Requirement                                 | Invoice Preview support? | Notes                                                                                                                                   |
| ------------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| Show exact charges incl. coupon & proration | ✅                       | Preview returns final `amount_due`.                                                                                                     |
| Two different billing schedules             | ✅                       | Call preview twice (monthly & annual) or preview combined _subscription schedule_ if you later merge them.                              |
| Coupons that apply to one or both           | ✅                       | Pass `coupon` or `discounts` per preview call.                                                                                          |
| Credit notes                                | ✅ (indirect)            | Create credit note after actual invoice; preview ignores credit notes, but you can subtract expected credit value for display purposes. |
| Avoid 24 h auto-cancellation                | ✅                       | We will create the subscriptions **after** the user has provided a PaymentMethod, so no unpaid PIs linger.                              |

**Conclusion:** The refactor _will_ work and greatly simplifies failure modes. Below is a concrete migration plan.

---

## 4 Step-by-Step Implementation Guide

> Keep current flow in production until the new one is fully tested. Use feature flags (`dashboard_invite_v2`) to opt-in users.

### 4.1 Database & Types

1. **payment_sessions**
   - **Keep** table but remove strict NOT NULL on the subscription / PI columns.
   - Add columns:
     ```sql
     ALTER TABLE payment_sessions
       ADD COLUMN IF NOT EXISTS customer_id TEXT,
       ADD COLUMN IF NOT EXISTS preview_monthly_amount INTEGER,
       ADD COLUMN IF NOT EXISTS preview_annual_amount INTEGER;
     ```
2. Update Kysely typings accordingly.

### 4.2 Supabase Edge Functions

#### 4.2.1 `bulk_invite_with_subscription` → _v2_

- **Change responsibility:**
  - Still **creates Supabase user** & **Stripe customer** (email only).
  - **DO NOT** create subscriptions or payment intents.
  - Insert `payment_sessions` row with `customer_id`, `coupon_id` (nullable), `expires_at` (+7 days), **no subscription ids yet**.
  - Return invitation email as before.

#### 4.2.2 `preview_invoice`

- **New function**.
- **Inputs:** `{ user_id, customer_id?, coupon_id? }`.
- **Flow:**
  1. If `customer_id` absent create Stripe customer → update `payment_sessions`.
  2. Fetch **price IDs** (same helper as today).
  3. **Monthly preview**:
     ```ts
     const monthly = await stripe.invoices.retrieveUpcoming({
     	customer,
     	subscription_items: [{ price: priceIds.monthly, quantity: 1 }],
     	coupon, // optional
     	subscription_date: Math.floor(Date.now() / 1000)
     });
     ```
  4. **Annual preview** (identical but price: `priceIds.annual`).
  5. Store `preview_monthly_amount`, `preview_annual_amount` (in cents) back to `payment_sessions`.
  6. Return JSON `{ monthlyAmount, annualAmount, totalAmount }`.
- **Security:** RLS not needed—service role only. Validate requesting session matches `user_id`.

#### 4.2.3 Coupon & Credit-note flow

- **apply_coupon** endpoint (you can keep using the existing `api/signup/coupon/[paymentSessionId]` route).
- **Inputs:** `{ paymentSessionId, code }`.
- **Behaviour**
  1. Look up the `payment_sessions` row, confirm it is still valid (`expires_at` in the future and `is_used = false`).
  2. **Migration code** (`code === DASHBOARD_MIGRATION_CODE`)
     - Write the code into `coupon_id` for audit purposes.
     - No discount is applied during preview; **after** the subscriptions are created (see step&nbsp;4.4) create a **credit note** against each first invoice to bring the amount-due to 0.
  3. **Regular coupon / promotion code**
     - Validate via `stripe.promotionCodes.list({ active: true, code })`.
     - Persist `coupon_id` in `payment_sessions`.
     - Re-invoke `preview_invoice` so the discounted `monthly`/`annual` amounts are cached in `payment_sessions` and shown to the user.
- **Frontend flow**
  _User enters coupon_ → call `apply_coupon` → reload pricing from `preview_invoice`.

Implementation tip: Re-use most of the current `coupon/[paymentSessionId]` logic—remove the direct subscription updates (they do not yet exist) and move the **credit-note creation** code into the final subscription-creation step outlined below.

### 4.3 Frontend (`/members/signup/[invitationId]`)

1. **`load` function**
   - Call new `preview_invoice` endpoint in parallel with invitation data.
   - Display amounts via existing `pricing-display.svelte` (remove local calc logic).
2. **Stripe Elements** remains but **only** collects the PaymentMethod (SEPA debit mandate).

### 4.4 Submit Action (`+page.server.ts` → `actions.default`)

Replace manual PI confirmation logic with:

```ts
const paymentMethodId = /* from confirmed SetupIntent */

const createSub = (price: string) =>
  stripe.subscriptions.create({
    customer: customer_id,
    items: [{ price }],
    coupon: coupon_id ?? undefined,
    default_payment_method: paymentMethodId,
    payment_behavior: 'default_incomplete',
    expand: ['latest_invoice.payment_intent'],
    collection_method: 'charge_automatically',
    proration_behavior: 'create_prorations',
  });

const [monthlySub, annualSub] = await Promise.all([
  createSub(priceIds.monthly),
  createSub(priceIds.annual),
]);

// Confirm both PaymentIntents (if status === 'requires_action' etc.)
```

- Store new subscription & PI IDs back to `payment_sessions` (for audit).
- Mark `is_used = true` at the end **only after both PIs succeed**.
- If `coupon_id` equals the migration code, loop over `monthlySub` and `annualSub`'s `latest_invoice` objects and create credit notes to zero any initial charge (mirrors legacy migration-discount behaviour).

### 4.5 Error Handling & Retries

- If confirmation of either PI fails, cancel the _failed_ subscription immediately to avoid dangling incompletes.
- Show error message as today; user can retry without new invite since no 24 h expiry.

### 4.6 Migrations & Roll-out

1. Deploy new DB columns (safe, additive).
2. Ship `preview_invoice` function & update client code behind feature flag.
3. Create `bulk_invite_with_subscription_v2` and toggle admin panel to call it.
4. Monitor Stripe dashboard for reduction in _canceled_ subscriptions.
5. Once stable, drop old columns and code paths.

### 4.7 Optional Enhancements

- **Subscription Schedule**: Instead of two subscriptions, create a _single_ subscription schedule with two phases (`annual`, `monthly`). This removes dual-invoice complexity; preview can simulate schedule via `phase_changes`. Requires larger refactor but supported by Invoice Preview.
- **Payment Link fallback**: For manual fixes send a Payment Link pointing to customer portal to re-enter payment method.
- **Credit Notes UI**: After invoice creation, credit notes can be previewed by computing expected credit and presenting alongside invoice preview.

---

## 5 Benefits

- **No more auto-cancellations** → nothing created until user is ready.
- **Cleaner UX** → preview shows exact cost; one confirmation click.
- **Simpler code** → invitation flow decoupled from billing logic.
- **Extensible** → easy to add additional subscription types or one-time setup fees, just include them in preview call.

---

_End of instructions._
