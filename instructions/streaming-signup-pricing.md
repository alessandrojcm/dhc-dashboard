# Implementing Streaming for Signup Pricing Information

This document outlines the steps to improve the performance of the member signup form by implementing SvelteKit streaming for the pricing information.

## Problem Statement

The current implementation in `src/routes/(public)/members/signup/(signup-form)/+page.server.ts` has a complex load function that:
1. Creates or retrieves Stripe subscriptions and payment intents
2. Processes pricing information
3. Returns all data at once

This makes the page load slow because it blocks rendering until all this processing is complete, even though the pricing information isn't needed for the initial render.

## Solution: SvelteKit Streaming

We'll use SvelteKit's streaming feature to:
1. Return essential user data immediately so the page can start rendering
2. Stream the pricing information as it becomes available
3. Keep using the payment_sessions table (not replacing it with cookies)
4. Maintain compatibility with the plan-pricing endpoint for coupon functionality

## Implementation Steps

### 1. Create Utility Functions (Already Done)

We've already created:
- `src/lib/server/subscriptionCreation.ts` - Handles subscription creation and validation
- `src/lib/server/pricingUtils.ts` - Generates pricing information

### 2. Modify the Load Function in +page.server.ts

1. Import the utility functions:
```typescript
import { createSubscriptionSession, getExistingPaymentSession, validateExistingSession } from '$lib/server/subscriptionCreation';
import { generatePricingInfo, getNextBillingDates } from '$lib/server/pricingUtils';
```

2. Restructure the load function to:
   - Return essential user data immediately
   - Return pricing information as a nested promise that will be streamed

```typescript
export const load: PageServerLoad = async ({ parent, cookies }) => {
  const { userData } = await parent();
  
  try {
    // Get invitation data first (essential for page rendering)
    const invitationData = await kysely.transaction().execute(async (trx) => {
      // Existing invitation retrieval code...
    });
    
    // Return essential data immediately, with pricing as a streamed promise
    return {
      form: await superValidate({}, valibot(memberSignupSchema), { errors: false }),
      userData: {
        firstName: invitationData.first_name,
        lastName: invitationData.last_name,
        email: userData.email,
        dateOfBirth: new Date(invitationData.date_of_birth),
        phoneNumber: invitationData.phone_number,
        pronouns: invitationData.pronouns,
        gender: invitationData.gender,
        medicalConditions: invitationData.medical_conditions
      },
      insuranceFormLink: supabaseServiceClient
        .from('settings')
        .select('value')
        .eq('key', 'insurance_form_link')
        .limit(1)
        .single()
        .then((result) => result.data?.value),
      // Stream these values
      streamed: {
        // This will be streamed to the client as it resolves
        pricingData: getPricingData(userData.id, invitationData.customer_id!, cookies)
      },
      // These are needed for the page but can be calculated immediately
      ...getNextBillingDates()
    };
  } catch (err) {
    console.error(err);
    error(404, {
      message: 'Something went wrong'
    });
  }
};

// Helper function to get pricing data (will be streamed)
async function getPricingData(userId: string, customerId: string, cookies: any) {
  // Get existing session and price IDs in parallel
  const [existingSession, priceIds] = await Promise.all([
    getExistingPaymentSession(userId),
    getPriceIds()
  ]);
  
  let subscriptionData;
  
  if (existingSession) {
    // Validate existing session
    subscriptionData = await validateExistingSession(existingSession);
  }
  
  if (!existingSession || !subscriptionData?.valid) {
    // Create new subscriptions if no valid existing session
    subscriptionData = await createSubscriptionSession(userId, customerId, priceIds);
  }
  
  // Set cookie with payment info
  cookies.set(
    STRIPE_SIGNUP_INFO,
    JSON.stringify({
      customerId: customerId,
      annualSubscriptionPaymentIntendId: subscriptionData.annualPaymentIntent.id,
      membershipSubscriptionPaymentIntendId: subscriptionData.monthlyPaymentIntent.id
    } satisfies StripePaymentInfo),
    { path: '/', httpOnly: true, secure: true, sameSite: 'strict' }
  );
  
  // Generate and return pricing info
  return generatePricingInfo(
    subscriptionData.monthlySubscription,
    subscriptionData.annualSubscription,
    subscriptionData.proratedMonthlyAmount,
    subscriptionData.proratedAnnualAmount,
    existingSession
  );
}
```

### 3. Update the Page Component to Handle Streamed Data

Modify `src/routes/(public)/members/signup/(signup-form)/+page.svelte` to handle streamed data:

```svelte
<script lang="ts">
  // Existing imports...
  
  const { data } = $props();
  // Access streamed data
  const { streamed, userData, nextMonthlyBillingDate, nextAnnualBillingDate } = data;
  
  // Rest of the component...
</script>

<!-- Show loading state while pricing data is loading -->
{#await streamed.pricingData}
  <div class="pricing-loading">
    <p>Loading pricing information...</p>
    <!-- Optional loading spinner -->
  </div>
{:then planPricing}
  <!-- Display pricing information -->
  <div class="pricing-info">
    <!-- Pricing display code using planPricing -->
  </div>
{:catch error}
  <div class="pricing-error">
    <p>Error loading pricing information: {error.message}</p>
  </div>
{/await}
```

### 4. Maintain Compatibility with Plan-Pricing Endpoint

The existing `/api/signup/plan-pricing` endpoint is still needed for coupon functionality. No changes are needed here as it operates independently of our streaming implementation.

## Benefits

1. **Improved Performance**: The page will start rendering immediately with essential user data
2. **Better User Experience**: Users can start filling out the form while pricing information loads
3. **Maintainability**: Complex business logic is abstracted into separate utility functions
4. **Compatibility**: Maintains compatibility with existing coupon functionality

## Testing

1. Test the signup flow to ensure the page loads faster
2. Verify that pricing information appears correctly once loaded
3. Test coupon application to ensure it still works with the streamed pricing data
4. Test with slow network conditions to ensure the loading state works correctly
