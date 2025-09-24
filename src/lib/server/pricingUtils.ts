import Dinero from 'dinero.js';
import type { KyselyDatabase, PlanPricing } from '$lib/types';
import dayjs from 'dayjs';
import { ANNUAL_FEE_LOOKUP, MEMBERSHIP_FEE_LOOKUP_NAME } from './constants';
import { stripeClient } from './stripe';
import type { getKyselyClient } from './kysely';
import * as Sentry from '@sentry/sveltekit';

// Interface for price IDs
interface PriceIds {
	monthly: string;
	annual: string;
}

// Fetch price IDs directly from Stripe
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

// Update the price cache in the settings table
async function updatePriceCache(
	prices: PriceIds,
	db: Awaited<ReturnType<typeof getKyselyClient>>
): Promise<void> {
	const now = new Date().toISOString();

	// Update cache in parallel using kysely transaction
	await db.transaction().execute(async (trx) => {
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

// Helper function to get price IDs from the settings table (cached) or from Stripe
export async function getPriceIds(
	db: Awaited<ReturnType<typeof getKyselyClient>>
): Promise<PriceIds> {
	try {
		// First try to get from settings table (cached values)
		const cachedPrices = await getCachedPriceIds(db);
		if (cachedPrices) {
			return cachedPrices;
		}

		// If not cached or expired, fetch from Stripe
		const freshPrices = await fetchPriceIdsFromStripe();

		// Update cache
		await updatePriceCache(freshPrices, db);

		return freshPrices;
	} catch (error) {
		Sentry.captureException(error);
		throw new Error(
			`Failed to get price IDs: ${error instanceof Error ? error.message : String(error)}`
		);
	}
}

// Get cached price IDs from the settings table
async function getCachedPriceIds(
	db: Awaited<ReturnType<typeof getKyselyClient>>
): Promise<PriceIds | null> {
	try {
		// Get both monthly and annual price IDs in a single query
		const priceData = await db
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

		// Check if cache is expired (older than 24 hours)
		const monthlyUpdatedAt = dayjs(monthlyData.updated_at);
		const annualUpdatedAt = dayjs(annualData.updated_at);
		const now = dayjs();

		if (now.diff(monthlyUpdatedAt, 'hour') > 24 || now.diff(annualUpdatedAt, 'hour') > 24) {
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

/**
 * Generates pricing information for display on the signup page
 */
export function generatePricingInfo({
	proratedPrice,
	monthlyFee,
	annualFee,
	proratedAnnualPrice,
	proratedMonthlyPrice,
	discountPercentage = 0,
	coupon = undefined,
	discountedMonthlyFee = undefined,
	discountedAnnualFee = undefined
}: {
	proratedPrice: number;
	monthlyFee: number;
	annualFee: number;
	proratedMonthlyPrice?: number;
	proratedAnnualPrice?: number;
	discountPercentage?: number;
	coupon?: string;
	discountedMonthlyFee?: number;
	discountedAnnualFee?: number;
}): PlanPricing {
	return {
		proratedPrice: Dinero({
			amount: proratedPrice,
			currency: 'EUR'
		}).toJSON(),
		proratedMonthlyPrice: Dinero({
			amount: proratedMonthlyPrice ?? proratedPrice,
			currency: 'EUR'
		}).toJSON(),
		proratedAnnualPrice: Dinero({
			amount: proratedAnnualPrice ?? proratedPrice,
			currency: 'EUR'
		}).toJSON(),
		monthlyFee: Dinero({
			amount: monthlyFee,
			currency: 'EUR'
		}).toJSON(),
		annualFee: Dinero({
			amount: annualFee,
			currency: 'EUR'
		}).toJSON(),
		...(discountedMonthlyFee
			? {
					discountedMonthlyFee: Dinero({
						amount: discountedMonthlyFee,
						currency: 'EUR'
					}).toJSON()
				}
			: {}),
		...(discountedAnnualFee
			? {
					discountedAnnualFee: Dinero({
						amount: discountedAnnualFee,
						currency: 'EUR'
					}).toJSON()
				}
			: {}),
		...(coupon ? { coupon } : {}),
		discountPercentage
	} as PlanPricing;
}

/**
 * Returns the next billing dates for monthly and annual subscriptions
 */
export function getNextBillingDates() {
	return {
		nextMonthlyBillingDate: dayjs().add(1, 'month').startOf('month').toDate(),
		nextAnnualBillingDate: dayjs().month(0).date(7).add(1, 'year').toDate()
	};
}
