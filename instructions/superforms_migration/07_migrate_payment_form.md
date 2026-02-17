# Step 7: Migrate Payment Form (Signup Flow)

## Objective

Migrate `payment-form.svelte` from Superforms/formsnap to Remote Functions. This is the most complex form in the migration due to its Stripe integration.

## File Locations

- **Component**: `src/routes/(public)/members/signup/[invitationId]/payment-form.svelte`
- **Server**: `src/routes/(public)/members/signup/[invitationId]/+page.server.ts`
- **Remote**: `src/routes/(public)/members/signup/[invitationId]/data.remote.ts`
- **Schema**: `src/lib/schemas/membersSignup.ts`

## Reference Implementation

Study the migrated member profile form as reference:
- `src/routes/dashboard/members/[memberId]/+page.svelte`
- `src/routes/dashboard/members/[memberId]/data.remote.ts`

## Current Implementation Analysis

### Old Imports (to be removed)
```typescript
import * as Form from '$lib/components/ui/form';
import { superForm } from 'sveltekit-superforms';
import { valibotClient } from 'sveltekit-superforms/adapters';
```

### Form Fields
| Field | Type | Notes |
|-------|------|-------|
| `nextOfKin` | text | Required |
| `nextOfKinNumber` | phone | Required, uses PhoneInput |
| `stripeConfirmationToken` | hidden | Set programmatically after Stripe flow |
| `couponCode` | string | Optional, injected from component state |

### Complex Logic to Preserve
1. **Stripe Elements submission** before form submit
2. **Confirmation token creation** via `stripe.createConfirmationToken()`
3. **Custom form submission** via `customRequest()` to inject extra data
4. **Result handling** for success/failure states with toasts

---

## Migration Steps

### Step 1: Update Schema (if needed)

The existing `memberSignupSchema` in `src/lib/schemas/membersSignup.ts` should work as-is:

```typescript
export const memberSignupSchema = v.object({
  nextOfKin: v.pipe(v.string(), v.nonEmpty('Please enter your next of kin.')),
  nextOfKinNumber: phoneNumberValidator('Phone number of your next of kin is required.'),
  insuranceFormSubmitted: v.optional(v.boolean()),
  stripeConfirmationToken: v.pipe(
    v.string(),
    v.nonEmpty('Something has gone wrong with your payment, please try again.')
  ),
  couponCode: v.optional(v.string())
});
```

### Step 2: Create Remote Form in `data.remote.ts`

Add a new `processPayment` remote form. Move the server action logic here:

```typescript
import { form, getRequestEvent } from '$app/server';
import { error } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';
import type Stripe from 'stripe';
import { memberSignupSchema } from '$lib/schemas/membersSignup';
import { invariant } from '$lib/server/invariant';
import { getKyselyClient } from '$lib/server/kysely';
import { getPriceIds } from '$lib/server/pricingUtils';
import { createInvitationService } from '$lib/server/services/invitations';
import { stripeClient } from '$lib/server/stripe';
import { env } from '$env/dynamic/public';

const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ?? 'DHCDASHBOARD';

export const processPayment = form(memberSignupSchema, async (data) => {
  const event = getRequestEvent();
  const invitationId = event.params.invitationId;

  if (!invitationId) {
    throw error(400, 'Invitation ID is required');
  }

  const kysely = getKyselyClient(event.platform?.env.HYPERDRIVE);
  const confirmationToken: Stripe.ConfirmationToken = JSON.parse(data.stripeConfirmationToken);
  const invitationService = createInvitationService(event.platform!);

  try {
    return await kysely.transaction().execute(async (trx) => {
      // Process invitation acceptance
      const invitationData = await invitationService.processInvitationAcceptance(
        trx,
        invitationId,
        data.nextOfKin,
        data.nextOfKinNumber
      );

      // Get customer ID
      const customerId = await trx
        .selectFrom('user_profiles')
        .select('customer_id')
        .where('supabase_user_id', '=', invitationData.user_id)
        .executeTakeFirst();

      if (!customerId) {
        throw error(404, 'No customer ID found for this user.');
      }

      // Create Stripe setup intent
      const intent = await stripeClient.setupIntents.create({
        confirm: true,
        customer: customerId.customer_id!,
        confirmation_token: confirmationToken.id,
        payment_method_types: ['sepa_debit']
      });

      invariant(intent.status === 'requires_payment_method', 'payment_intent_requires_payment_method');
      invariant(intent.payment_method == null, 'payment_method_not_found');

      const paymentMethodId =
        typeof intent.payment_method === 'string'
          ? intent.payment_method
          : (intent.payment_method! as Stripe.PaymentMethod).id;

      // Get price IDs
      const { monthly, annual } = await getPriceIds(kysely);
      if (!monthly || !annual) {
        Sentry.captureMessage('Base prices not found for membership products', {
          extra: { userId: invitationData.user_id }
        });
        throw error(500, 'Could not retrieve base product prices.');
      }

      // Handle promotion codes
      let isMigration = false;
      let promotionCodeId: string | undefined;
      if (data.couponCode) {
        const promotionCodes = await stripeClient.promotionCodes.list({
          active: true,
          code: data.couponCode,
          limit: 1
        });
        if (!promotionCodes.data.length) {
          throw error(400, 'Invalid or inactive promotion code');
        }
        if (data.couponCode.toLowerCase().trim() === DASHBOARD_MIGRATION_CODE.toLowerCase().trim()) {
          isMigration = true;
        } else {
          promotionCodeId = promotionCodes.data[0].id;
        }
      }

      // Create subscriptions (monthly and annual)
      await Promise.all([
        createMonthlySubscription(customerId.customer_id!, monthly, paymentMethodId, promotionCodeId, isMigration, event),
        createAnnualSubscription(customerId.customer_id!, annual, paymentMethodId, promotionCodeId, isMigration, event)
      ]);

      // Delete access token cookie on success
      event.cookies.delete('access-token', { path: '/' });

      return { paymentFailed: false };
    });
  } catch (err) {
    Sentry.captureException(err);
    const errorMessage = getStripeErrorMessage(err);
    return { paymentFailed: true, error: errorMessage };
  }
});

// Helper functions for subscription creation
async function createMonthlySubscription(
  customerId: string,
  priceId: string,
  paymentMethodId: string,
  promotionCodeId: string | undefined,
  isMigration: boolean,
  event: ReturnType<typeof getRequestEvent>
) {
  const subscription = await stripeClient.subscriptions.create({
    customer: customerId,
    items: [{ price: priceId }],
    billing_cycle_anchor_config: { day_of_month: 1 },
    payment_behavior: 'default_incomplete',
    payment_settings: { payment_method_types: ['sepa_debit'] },
    expand: ['latest_invoice.payments'],
    collection_method: 'charge_automatically',
    default_payment_method: paymentMethodId,
    discounts: !isMigration && promotionCodeId ? [{ promotion_code: promotionCodeId }] : undefined
  });

  return handleSubscriptionPayment(subscription, isMigration, paymentMethodId, event);
}

async function createAnnualSubscription(
  customerId: string,
  priceId: string,
  paymentMethodId: string,
  promotionCodeId: string | undefined,
  isMigration: boolean,
  event: ReturnType<typeof getRequestEvent>
) {
  const subscription = await stripeClient.subscriptions.create({
    customer: customerId,
    items: [{ price: priceId }],
    payment_behavior: 'default_incomplete',
    payment_settings: { payment_method_types: ['sepa_debit'] },
    billing_cycle_anchor_config: { month: 1, day_of_month: 7 },
    expand: ['latest_invoice.payments'],
    collection_method: 'charge_automatically',
    default_payment_method: paymentMethodId,
    discounts: !isMigration && promotionCodeId ? [{ promotion_code: promotionCodeId }] : undefined
  });

  return handleSubscriptionPayment(subscription, isMigration, paymentMethodId, event);
}

async function handleSubscriptionPayment(
  subscription: Stripe.Subscription,
  isMigration: boolean,
  paymentMethodId: string,
  event: ReturnType<typeof getRequestEvent>
) {
  const invoice = subscription.latest_invoice as Stripe.Invoice;
  if (invoice.payments?.data.length === 0) {
    return;
  }

  if (isMigration) {
    return stripeClient.creditNotes.create({
      invoice: invoice.id!,
      amount: invoice.amount_due
    });
  }

  return stripeClient.paymentIntents.confirm(
    invoice.payments?.data[0].payment.payment_intent as string,
    {
      payment_method: paymentMethodId,
      mandate_data: {
        customer_acceptance: {
          type: 'online',
          online: {
            ip_address: event.getClientAddress(),
            user_agent: event.request.headers.get('user-agent')!
          }
        }
      }
    }
  );
}

function getStripeErrorMessage(err: unknown): string {
  if (err instanceof Error && 'code' in err) {
    const stripeError = err as { code: string };
    switch (stripeError.code) {
      case 'charge_exceeds_source_limit':
      case 'charge_exceeds_transaction_limit':
        return 'The payment amount exceeds the account payment volume limit';
      case 'charge_exceeds_weekly_limit':
        return 'The payment amount exceeds the weekly transaction limit';
      case 'payment_intent_authentication_failure':
        return 'The payment authentication failed';
      case 'payment_method_unactivated':
        return 'The payment method is not activated';
      case 'payment_intent_payment_attempt_failed':
        return 'The payment attempt failed';
      default:
        return 'An error occurred with the payment processor';
    }
  }
  return 'An unexpected error occurred';
}
```

### Step 3: Migrate `payment-form.svelte`

#### 3.1 Update Imports

```diff
<script lang="ts">
- import * as Form from '$lib/components/ui/form';
+ import * as Field from '$lib/components/ui/field';
  import dayjs from 'dayjs';
  import { Input } from '$lib/components/ui/input';
  import { Button } from '$lib/components/ui/button';
- import { superForm } from 'sveltekit-superforms';
- import { valibotClient } from 'sveltekit-superforms/adapters';
  import { memberSignupSchema } from '$lib/schemas/membersSignup';
  // ... other imports stay the same
  import PhoneInput from '$lib/components/ui/phone-input.svelte';
+ import { processPayment } from './data.remote';
+ import { initForm } from '$lib/utils/init-form.svelte';
</script>
```

#### 3.2 Replace superForm initialization

```diff
- const form = superForm(props.form, {
-   validators: valibotClient(memberSignupSchema),
-   resetForm: false,
-   validationMethod: 'onblur',
-   // ... rest of config
- });
- const { form: formData, enhance, submitting } = form;

+ // Initialize form with empty values
+ initForm(processPayment, () => ({
+   nextOfKin: '',
+   nextOfKinNumber: '',
+   stripeConfirmationToken: '',
+   couponCode: ''
+ }));
```

#### 3.3 Use `enhance` for custom Stripe submission

The `enhance` method allows custom logic before/after form submission. This replaces Superforms' `customRequest`:

```svelte
<form
  {...processPayment.enhance(async ({ form, data, submit }) => {
    // 1. Validate Stripe is ready
    if (!stripe || !elements) {
      toast.error('Payment system not initialized');
      return; // Don't call submit()
    }

    // 2. Submit Stripe elements first
    const { error: elementsError } = await elements.submit();
    if (elementsError?.message) {
      toast.error(elementsError.message);
      return;
    }

    // 3. Create confirmation token
    const { error: paymentMethodError, confirmationToken } = await stripe.createConfirmationToken({
      elements,
      params: {
        return_url: window.location.href + '/members/signup'
      }
    });

    if (paymentMethodError?.message) {
      toast.error(paymentMethodError.message);
      return;
    }

    // 4. Set the token and coupon in form data before submission
    processPayment.fields.stripeConfirmationToken.set(JSON.stringify(confirmationToken));
    processPayment.fields.couponCode.set(currentCoupon);

    // 5. Now submit the form
    try {
      await submit();
      // Success is handled via processPayment.result
    } catch (error) {
      toast.error('Something went wrong with your payment');
    }
  })}
  class="space-y-6"
>
```

**Key points:**
- `submit()` is only called after Stripe flow succeeds
- If any step fails, we return early without calling `submit()`
- Form data is set via `processPayment.fields.*.set()` before `submit()`

#### 3.4 Handle form results

```typescript
$effect(() => {
  const result = processPayment.result;
  if (result?.paymentFailed === false) {
    showThanks = true;
  } else if (result?.paymentFailed) {
    toast.error(result.error || 'Payment failed');
  }
});
```

#### 3.5 Alternative: Simple spread (if no custom logic needed)

For simple forms without custom submit logic, just spread the form:

```svelte
<form {...processPayment} class="space-y-6">
```

#### 3.6 Replace Form.Field with Field components

**Before:**
```svelte
<Form.Field {form} name="nextOfKin">
  <Form.Control>
    {#snippet children({ props })}
      <Form.Label>Next of Kin</Form.Label>
      <Input
        {...props}
        bind:value={$formData.nextOfKin}
        placeholder="Full name of your next of kin"
      />
    {/snippet}
  </Form.Control>
  <Form.FieldErrors />
</Form.Field>
```

**After:**
```svelte
<Field.Field>
  {@const fieldProps = processPayment.fields.nextOfKin.as('text')}
  <Field.Label for={fieldProps.name}>Next of Kin</Field.Label>
  <Input
    {...fieldProps}
    id={fieldProps.name}
    placeholder="Full name of your next of kin"
  />
  {#each processPayment.fields.nextOfKin.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

#### 3.7 Fix PhoneInput (remove bind:phoneNumber)

**Before:**
```svelte
<PhoneInput
  placeholder="Enter your next of kin's phone number"
  {...props}
  bind:phoneNumber={$formData.nextOfKinNumber}
/>
```

**After:**
```svelte
{@const fieldProps = processPayment.fields.nextOfKinNumber.as('tel')}
<PhoneInput
  {...fieldProps}
  id={fieldProps.name}
  placeholder="Enter your next of kin's phone number"
/>
```

The `PhoneInput` component already:
- Accepts `value` prop (via spread)
- Has a hidden input with `name` attribute
- Handles `onChange` internally

#### 3.8 Update submit button

```svelte
<Button type="submit" class="ml-auto" disabled={!!processPayment.pending}>
  {#if processPayment.pending}
    <LoaderCircle />
  {:else}
    Sign up
    <ArrowRightIcon class="ml-2 h-4 w-4" />
  {/if}
</Button>
```

### Step 4: Update `+page.server.ts`

Remove the `actions` export completely. Keep only the `load` function:

```diff
- import { fail, message, superValidate } from 'sveltekit-superforms';
- import { valibot } from 'sveltekit-superforms/adapters';
- import { memberSignupSchema } from '$lib/schemas/membersSignup';

  export const load: PageServerLoad = async ({ params, platform, cookies }) => {
    // ... keep existing load logic
    return {
-     form: await superValidate({}, valibot(memberSignupSchema), {
-       errors: false
-     }),
      userData: { ... },
      isConfirmed,
      insuranceFormLink: '',
      ...getNextBillingDates()
    };
  };

- export const actions: Actions = {
-   default: async (event) => { ... }
- };
```

### Step 5: Update Props in Component

Since we removed `form` from the server load:

```diff
- const props: PageServerData = $props();
+ const { data } = $props();

- const { nextMonthlyBillingDate, nextAnnualBillingDate } = props;
+ const { nextMonthlyBillingDate, nextAnnualBillingDate } = data;

- {props.userData.firstName}
+ {data.userData.firstName}
```

---

## Complete Migrated Component

See the reference implementation pattern from `src/routes/dashboard/members/[memberId]/+page.svelte` for the full structure.

---

## Testing Checklist

After migration, verify:

- [ ] Form renders correctly with empty fields
- [ ] Validation errors display for required fields
- [ ] Phone input works correctly (country selector, formatting)
- [ ] Stripe elements initialize and mount
- [ ] Stripe submission flow works (elements.submit → createConfirmationToken)
- [ ] Form submission sends all data correctly
- [ ] Success state shows thank you message
- [ ] Error handling displays appropriate toast messages
- [ ] Coupon code application still works
- [ ] Type checking passes: `pnpm check`

## Rollback Plan

If issues arise:
1. Revert the component changes
2. Restore the `actions` export in `+page.server.ts`
3. Keep the `data.remote.ts` changes (they won't interfere)
