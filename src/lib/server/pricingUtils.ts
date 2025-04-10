import Dinero from 'dinero.js';
import type { PlanPricing } from '$lib/types';
import type { SubscriptionWithPlan } from '$lib/types';
import dayjs from 'dayjs';
import type { ExistingSession } from '$lib/server/subscriptionCreation.ts';

/**
 * Generates pricing information for display on the signup page
 */
export function generatePricingInfo(
	monthlySubscription: SubscriptionWithPlan,
	annualSubscription: SubscriptionWithPlan,
	proratedMonthlyAmount: number,
	proratedAnnualAmount: number,
	existingSession?: ExistingSession
): PlanPricing {
	return {
		proratedPrice: Dinero({
			// Use the total prorated amount that the user will pay now
			amount: proratedMonthlyAmount + proratedAnnualAmount,
			currency: 'EUR'
		}).toJSON(),
		proratedMonthlyPrice: Dinero({
			amount: proratedMonthlyAmount,
			currency: 'EUR'
		}).toJSON(),
		proratedAnnualPrice: Dinero({
			amount: proratedAnnualAmount,
			currency: 'EUR'
		}).toJSON(),
		monthlyFee: Dinero({
			amount: monthlySubscription.plan.amount!,
			currency: 'EUR'
		}).toJSON(),
		annualFee: Dinero({
			amount: annualSubscription.plan.amount!,
			currency: 'EUR'
		}).toJSON(),
		// Include discounted amounts if they exist
		...(existingSession?.discounted_monthly_amount && {
			discountedMonthlyFee: Dinero({
				amount: existingSession.discounted_monthly_amount,
				currency: 'EUR'
			}).toJSON()
		}),
		...(existingSession?.discounted_annual_amount && {
			discountedAnnualFee: Dinero({
				amount: existingSession.discounted_annual_amount,
				currency: 'EUR'
			}).toJSON()
		}),
		// Use stored discount percentage if available, otherwise calculate it
		...(existingSession?.discount_percentage
			? {
					discountPercentage: existingSession.discount_percentage
				}
			: existingSession?.discounted_monthly_amount
				? {
						discountPercentage: Math.round(
							(((monthlySubscription as unknown as SubscriptionWithPlan).plan.amount! -
								existingSession.discounted_monthly_amount) /
								(monthlySubscription as unknown as SubscriptionWithPlan).plan.amount!) *
								100
						)
					}
				: {}),
		coupon: existingSession?.coupon_id ?? undefined
	} as PlanPricing;
}

/**
 * Returns the next billing dates for monthly and annual subscriptions
 */
export function getNextBillingDates() {
	return {
		nextMonthlyBillingDate: dayjs().add(1, 'month').startOf('month').toDate(),
		nextAnnualBillingDate: dayjs().add(1, 'year').startOf('year').set('date', 7).toDate()
	};
}
