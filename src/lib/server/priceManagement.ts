import { stripeClient } from '$lib/server/stripe';
import { MEMBERSHIP_FEE_LOOKUP_NAME, ANNUAL_FEE_LOOKUP } from '$lib/server/constants';
import dayjs from 'dayjs';
import type { Kysely } from 'kysely';
import type { KyselyDatabase } from '$lib/types';
import * as Sentry from '@sentry/sveltekit';

interface PriceIds {
	monthly: string;
	annual: string;
}

// Cache expiry in hours
const CACHE_EXPIRY_HOURS = 24;

export async function getPriceIds(kysely: Kysely<KyselyDatabase>): Promise<PriceIds> {
	// Try to get cached price IDs first
	const cachedPrices = await getCachedPriceIds(kysely);
	if (cachedPrices) {
		return cachedPrices;
	}

	// If not cached or expired, fetch from Stripe
	const freshPrices = await fetchPriceIdsFromStripe();

	// Update cache
	await updatePriceCache(freshPrices, kysely);

	return freshPrices;
}

async function getCachedPriceIds(kysely: Kysely<KyselyDatabase>): Promise<PriceIds | null> {
	try {
		// Get both monthly and annual price IDs in a single query
		const priceData = await kysely
			.selectFrom('settings')
			.select(['key', 'value', 'updated_at'])
			.where('key', 'in', ['stripe_monthly_price_id', 'stripe_annual_price_id'])
			.execute();

		// Extract monthly and annual data from results
		const monthlyData = priceData.find((item) => item.key === 'stripe_monthly_price_id');
		const annualData = priceData.find((item) => item.key === 'stripe_annual_price_id');

		// If either data is missing, return null
		if (!monthlyData || !annualData) {
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
	} catch (error) {
		Sentry.captureException(error);
		return null;
	}
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

async function updatePriceCache(prices: PriceIds, kysely: Kysely<KyselyDatabase>): Promise<void> {
	const now = new Date().toISOString();

	// Update cache in parallel using kysely transaction
	await kysely.transaction().execute(async (trx) => {
		await Promise.all([
			trx
				.updateTable('settings')
				.set({
					value: prices.monthly,
					updated_at: now
				})
				.where('key', '=', 'stripe_monthly_price_id')
				.execute(),
			trx
				.updateTable('settings')
				.set({
					value: prices.annual,
					updated_at: now
				})
				.where('key', '=', 'stripe_annual_price_id')
				.execute()
		]);
	});
}
