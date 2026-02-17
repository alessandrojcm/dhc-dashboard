# Stripe Price Caching Implementation

This document outlines the steps to implement Stripe price caching using the settings table and pg_cron to improve the performance of the member signup process.

## 1. Create Price Management Helper Functions

Create a new file `src/lib/server/priceManagement.ts`:

```typescript
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import { stripeClient } from '$lib/server/stripe';
import { MEMBERSHIP_FEE_LOOKUP_NAME, ANNUAL_FEE_LOOKUP } from '$lib/server/constants';
import dayjs from 'dayjs';

interface PriceIds {
	monthly: string;
	annual: string;
}

// Cache expiry in hours
const CACHE_EXPIRY_HOURS = 24;

export async function getPriceIds(): Promise<PriceIds> {
	// Try to get cached price IDs first
	const cachedPrices = await getCachedPriceIds();
	if (cachedPrices) {
		return cachedPrices;
	}

	// If not cached or expired, fetch from Stripe
	const freshPrices = await fetchPriceIdsFromStripe();

	// Update cache
	await updatePriceCache(freshPrices);

	return freshPrices;
}

async function getCachedPriceIds(): Promise<PriceIds | null> {
	// Get monthly price ID
	const { data: monthlyData, error: monthlyError } = await supabaseServiceClient
		.from('settings')
		.select('value, updated_at')
		.eq('key', 'stripe_monthly_price_id')
		.single();

	// Get annual price ID
	const { data: annualData, error: annualError } = await supabaseServiceClient
		.from('settings')
		.select('value, updated_at')
		.eq('key', 'stripe_annual_price_id')
		.single();

	// If either query failed or data is missing, return null
	if (monthlyError || annualError || !monthlyData || !annualData) {
		return null;
	}

	// Check if cache is expired (older than CACHE_EXPIRY_HOURS)
	const monthlyUpdatedAt = dayjs(monthlyData.updated_at);
	const annualUpdatedAt = dayjs(annualData.updated_at);
	const now = dayjs();

	if (
		now.diff(monthlyUpdatedAt, 'hour') > CACHE_EXPIRY_HOURS ||
		now.diff(annualUpdatedAt, 'hour') > CACHE_EXPIRY_HOURS
	) {
		return null;
	}

	// Return cached price IDs
	return {
		monthly: monthlyData.value,
		annual: annualData.value
	};
}

async function fetchPriceIdsFromStripe(): Promise<PriceIds> {
	// Fetch prices from Stripe in parallel
	const [monthlyPrices, annualPrices] = await Promise.all([
		stripeClient.prices.list({
			lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME],
			active: true,
			limit: 1
		}),
		stripeClient.prices.list({
			lookup_keys: [ANNUAL_FEE_LOOKUP],
			active: true,
			limit: 1
		})
	]);

	// Extract price IDs
	const monthlyPriceId = monthlyPrices.data[0]?.id;
	const annualPriceId = annualPrices.data[0]?.id;

	if (!monthlyPriceId || !annualPriceId) {
		throw new Error('Failed to retrieve price IDs from Stripe');
	}

	return {
		monthly: monthlyPriceId,
		annual: annualPriceId
	};
}

async function updatePriceCache(prices: PriceIds): Promise<void> {
	const now = new Date().toISOString();

	// Update cache in parallel
	await Promise.all([
		supabaseServiceClient.from('settings').upsert({
			key: 'stripe_monthly_price_id',
			value: prices.monthly,
			updated_at: now
		}),
		supabaseServiceClient.from('settings').upsert({
			key: 'stripe_annual_price_id',
			value: prices.annual,
			updated_at: now
		})
	]);
}

// Function to be called by pg_cron
export async function refreshPriceCache(): Promise<void> {
	try {
		const freshPrices = await fetchPriceIdsFromStripe();
		await updatePriceCache(freshPrices);
		console.log('Price cache refreshed successfully');
	} catch (error) {
		console.error('Failed to refresh price cache:', error);
	}
}
```

## 2. Create pg_cron Migration

Create a new migration file `supabase/migrations/YYYYMMDDHHMMSS_add_price_cache_cron.sql`:

```sql
-- Enable the pg_cron extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Insert initial price cache entries if they don't exist
INSERT INTO settings (key, value, updated_at)
VALUES
  ('stripe_monthly_price_id', '', NOW()),
  ('stripe_annual_price_id', '', NOW())
ON CONFLICT (key) DO NOTHING;

-- Create a database function to refresh price cache
CREATE OR REPLACE FUNCTION refresh_stripe_price_cache()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  monthly_price_id TEXT;
  annual_price_id TEXT;
  stripe_key TEXT;
  api_url TEXT;
  monthly_response JSONB;
  annual_response JSONB;
BEGIN
  -- Get Stripe API key from secure storage
  -- This assumes you have a secure way to store the Stripe key in the database
  -- You might need to adjust this based on your actual implementation
  SELECT value INTO stripe_key FROM settings WHERE key = 'stripe_secret_key';

  IF stripe_key IS NULL THEN
    RAISE EXCEPTION 'Stripe API key not found';
  END IF;

  -- Fetch monthly price
  api_url := 'https://api.stripe.com/v1/prices?lookup_keys[]=' ||
             (SELECT value FROM settings WHERE key = 'membership_fee_lookup_name') ||
             '&active=true&limit=1';

  SELECT
    content::jsonb INTO monthly_response
  FROM
    http_post(
      api_url,
      '',
      'application/x-www-form-urlencoded',
      array[
        ('Authorization', 'Bearer ' || stripe_key)::http_header
      ]
    );

  -- Extract monthly price ID
  monthly_price_id := monthly_response->'data'->0->>'id';

  -- Fetch annual price
  api_url := 'https://api.stripe.com/v1/prices?lookup_keys[]=' ||
             (SELECT value FROM settings WHERE key = 'annual_fee_lookup') ||
             '&active=true&limit=1';

  SELECT
    content::jsonb INTO annual_response
  FROM
    http_post(
      api_url,
      '',
      'application/x-www-form-urlencoded',
      array[
        ('Authorization', 'Bearer ' || stripe_key)::http_header
      ]
    );

  -- Extract annual price ID
  annual_price_id := annual_response->'data'->0->>'id';

  -- Update settings table with new price IDs
  UPDATE settings SET value = monthly_price_id, updated_at = NOW()
  WHERE key = 'stripe_monthly_price_id';

  UPDATE settings SET value = annual_price_id, updated_at = NOW()
  WHERE key = 'stripe_annual_price_id';

  RAISE NOTICE 'Price cache updated: Monthly=%, Annual=%', monthly_price_id, annual_price_id;
END;
$$;

-- Schedule the cron job to run daily at 3:00 AM
SELECT cron.schedule('refresh-stripe-prices', '0 3 * * *', 'SELECT refresh_stripe_price_cache()');

-- Note: If you need to manually run this function:
-- SELECT refresh_stripe_price_cache();

-- Note: To remove the cron job if needed:
-- SELECT cron.unschedule('refresh-stripe-prices');
```

## 3. Update the Signup Page Server Load Function

Modify `src/routes/(public)/members/signup/(signup-form)/+page.server.ts`:

```typescript
import { getPriceIds } from '$lib/server/priceManagement';
// ... other imports

export const load: PageServerLoad = async ({ parent, cookies }) => {
	const { userData } = await parent();
	try {
		// Run these operations in parallel for better performance
		const [invitationData, existingSession, priceIds] = await Promise.all([
			kysely.transaction().execute(async (trx) => {
				// Get invitation info
				const invitationInfo = await getInvitationInfo(userData.id, trx);

				if (!invitationInfo || invitationInfo.status !== 'pending') {
					throw error(404, {
						message: 'Invalid invitation'
					});
				}

				// Rest of your invitation logic
				return invitationInfo;
			}),
			kysely
				.selectFrom('payment_sessions')
				.select([
					'monthly_subscription_id',
					'annual_subscription_id',
					'monthly_payment_intent_id',
					'annual_payment_intent_id',
					'monthly_amount',
					'annual_amount',
					'coupon_id'
				])
				.where('user_id', '=', userData.id)
				.where('expires_at', '>', dayjs().toISOString())
				.where('is_used', '=', false)
				.orderBy('created_at', 'desc')
				.executeTakeFirst(),
			getPriceIds() // Get cached price IDs
		]);

		// Rest of your function using priceIds.monthly and priceIds.annual
		// instead of fetching from Stripe each time

		// When creating subscriptions:
		if (!existingSession || !validExistingSession) {
			const [monthlySubscription, annualSubscription] = await Promise.all([
				stripeClient.subscriptions.create({
					customer: customer.id,
					items: [
						{
							price: priceIds.monthly // Use cached price ID
							// ...
						}
					]
					// ...
				}),
				stripeClient.subscriptions.create({
					customer: customer.id,
					items: [
						{
							price: priceIds.annual // Use cached price ID
							// ...
						}
					]
					// ...
				})
			]);

			// Rest of your subscription handling
		}

		// Rest of your function
	} catch (e) {
		// Error handling
	}
};
```

## 4. Update the Plan Pricing API Endpoint

Modify `src/routes/api/signup/plan-pricing/+server.ts`:

```typescript
import { getPriceIds } from '$lib/server/priceManagement';
// ... other imports

export const GET: RequestHandler = async ({ url, locals }) => {
	try {
		// Get user ID from session
		const session = await locals.getSession();
		if (!session) {
			throw error(401, 'Unauthorized');
		}

		// Get cached price IDs
		const priceIds = await getPriceIds();

		// Rest of your function using priceIds instead of fetching from Stripe

		return json({
			// Your response
		});
	} catch (e) {
		// Error handling
	}
};
```

## 5. Initialize Price Cache

Run this SQL query in your database to initialize the price cache:

```sql
-- Run this manually to initialize the price cache
SELECT refresh_stripe_price_cache();
```

## 6. Update Tests

Update your tests to mock the price cache:

```typescript
// e2e/coupon-code.spec.ts or similar

// Mock the price IDs function
vi.mock('$lib/server/priceManagement', () => ({
	getPriceIds: vi.fn().mockResolvedValue({
		monthly: 'price_mock_monthly',
		annual: 'price_mock_annual'
	})
}));

// Your test code
```

## 7. Performance Monitoring

After implementing these changes, monitor the performance improvements:

1. Check server logs for Stripe API call frequency
2. Monitor the signup page load time
3. Verify that the pg_cron job is running correctly
4. Check the settings table to ensure price IDs are being updated

## Additional Notes

- The pg_cron job will refresh the price cache daily at 3:00 AM
- If prices change in Stripe, they will be automatically updated within 24 hours
- You can manually trigger a cache refresh by calling `SELECT refresh_stripe_price_cache();`
- Make sure the database user has the necessary permissions to use pg_cron
