import Dinero from 'dinero.js';
import type { PlanPricing } from '$lib/types';
import type { SubscriptionWithPlan } from '$lib/types';
import dayjs from 'dayjs';

/**
 * Generates pricing information for display on the signup page
 */
export function generatePricingInfo({
	proratedPrice,
	monthlyFee,
	annualFee,
	discountPercentage = 0,
	coupon = undefined,
	discountedMonthlyFee = undefined,
	discountedAnnualFee = undefined
}: {
	proratedPrice: number;
	monthlyFee: number;
	annualFee: number;
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
			amount: proratedPrice,
			currency: 'EUR'
		}).toJSON(),
		proratedAnnualPrice: Dinero({
			amount: proratedPrice,
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
		...(discountedMonthlyFee ? {
			discountedMonthlyFee: Dinero({
				amount: discountedMonthlyFee,
				currency: 'EUR'
			}).toJSON()
		} : {}),
		...(discountedAnnualFee ? {
			discountedAnnualFee: Dinero({
				amount: discountedAnnualFee,
				currency: 'EUR'
			}).toJSON()
		} : {}),
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
