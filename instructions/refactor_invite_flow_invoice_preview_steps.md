# Invoice Preview Refactor – Detailed Step-by-Step Implementation Guide

> This document breaks the migration into **actionable tasks** you can tick off one by one.  
> Suggested order keeps prod stable while you iterate behind a feature flag (`dashboard_invite_v2`).

---

## 0. Pre-Requisites

1. Ensure **Supabase** and **Cloudflare Workers** env-vars are set (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_SECRET_KEY`, etc.).
2. Verify Stripe API version `2024-08-16` (or later) in the Stripe dashboard → Developers → API versions.
3. Pull latest `supabase/migrations` locally and run `supabase db reset` (dev only).

---

## 1. Database Migrations

```sql
-- 1.1 Add new columns (safe, additive)
ALTER TABLE public.payment_sessions
  ADD COLUMN IF NOT EXISTS preview_monthly_amount INTEGER,
  ADD COLUMN IF NOT EXISTS preview_annual_amount INTEGER,
  ADD COLUMN IF NOT EXISTS discounted_monthly_amount INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discounted_annual_amount INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discount_percentage INTEGER;

-- 1.2 Relax NOT-NULL on subscription / payment-intent columns
ALTER TABLE public.payment_sessions
  ALTER COLUMN monthly_subscription_id DROP NOT NULL,
  ALTER COLUMN annual_subscription_id DROP NOT NULL,
  ALTER COLUMN monthly_payment_intent_id DROP NOT NULL,
  ALTER COLUMN annual_payment_intent_id DROP NOT NULL;
```

1.3 `pnpm kysely-codegen` to update Kysely types.

---

## 2. Update Edge Function `bulk_invite_with_subscription`

| Change          | File                                                                                               | Action                                          |
| --------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Modify in place | `supabase/functions/bulk_invite_with_subscription/index.ts`                                        | Remove subscription creation & payment intents. |
| Insert new row  | `createPaymentSession` now stores **only**: `user_id`, `coupon_id`, `expires_at = NOW() + 7 days`. |
| Return payload  | JSON `{ invitation_ids, paymentSessionId }`                                                        |

Deploy with `supabase functions deploy bulk_invite_with_subscription`.

---

## 3. Preview Invoice Endpoint

### 3.1 Route skeleton

`src/routes/api/signup/preview-invoice/[invitationId]/+server.ts`

```ts
import { stripeClient } from '$lib/server/stripe';
import { getKyselyClient } from '$lib/server/kysely';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ params, platform }) => {
	const db = getKyselyClient(platform.env.HYPERDRIVE);

	const session = await db
		.selectFrom('payment_sessions')
		.selectAll()
		.where(
			'user_id',
			'=',
			db.selectFrom('invitations').select('user_id').where('id', '=', params.invitationId)
		)
		.executeTakeFirstOrThrow();

	// customer_id is stored on user_profiles
	const userProfile = await db
		.selectFrom('user_profiles')
		.select('customer_id')
		.where('supabase_user_id', '=', session.user_id)
		.executeTakeFirst();
	const customerId = userProfile?.customer_id ?? assertNever();

	const priceIds = await fetchPriceIds();
	const coupon = session.coupon_id ?? undefined;
	const ts = Math.floor(Date.now() / 1000);

	const [monthly, annual] = await Promise.all([
		stripeClient.invoices.retrieveUpcoming({
			customer: customerId,
			subscription_items: [{ price: priceIds.monthly }],
			coupon,
			subscription_date: ts
		}),
		stripeClient.invoices.retrieveUpcoming({
			customer: customerId,
			subscription_items: [{ price: priceIds.annual }],
			coupon,
			subscription_date: ts
		})
	]);

	await db
		.updateTable('payment_sessions')
		.set({ preview_monthly_amount: monthly.amount_due, preview_annual_amount: annual.amount_due })
		.where('id', '=', session.id)
		.execute();

	return Response.json({
		monthlyAmount: monthly.amount_due,
		annualAmount: annual.amount_due,
		totalAmount: monthly.amount_due + annual.amount_due
	});
};
```

### 3.2 Helper `fetchPriceIds()`

Reuse existing helper from the Edge function in a shared lib (`$lib/server/stripePriceCache.ts`).

---

## 4. Coupon Application Route

_Rename_: keep `src/routes/api/signup/coupon/[paymentSessionId]/+server.ts` but **strip out** subscription-update code.

Algorithm:

1. Validate code (`DASHBOARD_MIGRATION_CODE` short-circuit).
2. For regular coupons: store `coupon_id`, compute `discount_percentage`, then **call `refreshPreviewAmounts()` helper** (see Section 3.2) to recalculate and persist discounted amounts **without making an internal HTTP call**.
3. Respond `{ message: 'Coupon applied', pricing: updatedPricing }` so UI can re-render.

> No credit-note creation here – moved to Step 6.

---

## 5. Frontend Updates

### 5.1 `/members/signup/[invitationId]/+page.server.ts`

| Task         | Diff                                                                                                                             |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Load pricing | Call `refreshPreviewAmounts()` inside the preview route and return JSON; page uses that. No extra fetch from coupon route.       |
| Display      | `pricing-display.svelte` use `pricing.monthlyAmount`, `pricing.annualAmount`, fallback to `preview_*` columns.                   |
| Coupon form  | POST to `/api/signup/coupon/{paymentSessionId}`; response includes `pricing` so you can update state without additional request. |

### 5.2 `pricing-display.svelte`

Remove old prorate math; just show props.

---

## 6. Signup Action (`actions.default`)

1. Retrieve `payment_session` inside transaction.
2. Create `paymentMethodId` (existing SEPA flow).
3. Function `createSub(price)` (see instructions file) – include `coupon` if present.
4. After both subs succeed:
   - `UPDATE payment_sessions` with subscription IDs, PI IDs, `is_used = true`.
   - **If `coupon_id === DASHBOARD_MIGRATION_CODE`** create credit note for each `sub.latest_invoice`:
     ```ts
     await stripeClient.creditNotes.create({
     	invoice: invoice.id,
     	amount: invoice.amount_due,
     	reason: 'order_change',
     	memo: 'Migration discount'
     });
     ```

5. Commit transaction.

---

## 7. Deployment

Deploy updated Cloudflare Worker and Supabase functions; the old flow is removed, no feature flags retained.

---

## 8. QA Checklist

- [ ] Edge function returns 200 and writes minimal `payment_sessions`.
- [ ] Preview endpoint returns expected amounts (check with test coupons).
- [ ] Coupon route refreshes preview.
- [ ] Sign-up completes → two active subs, no auto-cancel after 24 h.
- [ ] Migration code path: subs invoices show 0 after credit-notes.
- [ ] RLS policies unaffected (service-role only).

---

## 9. Monitoring & Rollback

- **Stripe Dashboard** → Subscriptions filter: status `incomplete_expired` should trend ↓.
- Cloudflare Workers logs for 5xx from new endpoints.
- Rollback: re-deploy previous commit of the worker & Supabase function if needed.

---

_End of detailed guide._
