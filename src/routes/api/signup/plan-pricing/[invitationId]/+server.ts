import type { RequestEvent } from '@sveltejs/kit';
import { getKyselyClient } from '$lib/server/kysely';
import { getExistingPaymentSession } from '$lib/server/subscriptionCreation';
import { error } from '@sveltejs/kit';
import type { SubscriptionWithPlan } from '$lib/types';
import { refreshPreviewAmounts } from '$lib/server/stripePriceCache';
import { generatePricingInfo } from '$lib/server/pricingUtils';

/**
 * Consolidated endpoint for plan pricing and invoice preview
 * Handles both basic pricing information and detailed invoice preview with proration and discounts
 */
export async function GET({ params, platform = {}, url }: RequestEvent) {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	
	// Get invitation and user data
	const invitation = await kysely
		.selectFrom('invitations')
		.select(['user_id', 'id'])
		.where(eb => eb('id', '=', params?.invitationId || ''))
		.where(eb => eb('status', '=', 'pending'))
		.executeTakeFirst();
	
	if (!invitation || !invitation.user_id) {
		throw error(404, 'Invalid invitation');
	}
	
	// Get payment session data with all necessary fields
	const paymentSession = await kysely
		.selectFrom('payment_sessions')
		.select('id')
		.select('coupon_id')
		.select('monthly_amount')
		.select('annual_amount')
		.select('preview_monthly_amount')
		.select('preview_annual_amount')
		.select('discount_percentage')
		// Note: These columns will be available after the migration is applied
		// For now, we'll handle their absence gracefully
		.leftJoin('user_profiles', 'user_profiles.supabase_user_id', 'payment_sessions.user_id')
		.select(['customer_id'])
		.where(eb => eb('payment_sessions.user_id', '=', invitation.user_id))
		.where(eb => eb('payment_sessions.is_used', '=', false))
		.executeTakeFirst();

	if (!paymentSession || !paymentSession.customer_id) {
		throw error(404, 'Invalid payment session');
	}
	
	// Check if we should force refresh the preview amounts
	const forceRefresh = url.searchParams.get('refresh') === 'true';
	
	// If we have preview amounts and we're not forcing a refresh, use the existing data
	if (!forceRefresh && 
		paymentSession.preview_monthly_amount && 
		paymentSession.preview_annual_amount) {
		// Get the full payment session with all fields
		const fullSession = await getExistingPaymentSession(invitation.user_id, kysely);
		
		if (fullSession) {
			// Create the pricing info directly from the payment session data
			const monthlySubscription = {
				plan: { amount: fullSession.monthly_amount }
			} as unknown as SubscriptionWithPlan;

			const annualSubscription = {
				plan: { amount: fullSession.annual_amount }
			} as unknown as SubscriptionWithPlan;
			
			// Use existing preview amounts
			const monthlyAmount = paymentSession.preview_monthly_amount || fullSession.monthly_amount;
			const annualAmount = paymentSession.preview_annual_amount || fullSession.annual_amount;
			
			// Calculate prorated amounts manually until migration is applied
			// In the future, these will come from the database
			const proratedMonthlyAmount = 0; // Will be populated by migration
			const proratedAnnualAmount = 0; // Will be populated by migration
			
			return Response.json({
				pricingInfo: generatePricingInfo(
					monthlySubscription,
					annualSubscription,
					proratedMonthlyAmount,
					proratedAnnualAmount,
					fullSession
				),
				monthlyAmount,
				annualAmount,
				proratedMonthlyAmount,
				proratedAnnualAmount,
				totalAmount: monthlyAmount + annualAmount,
				discountPercentage: paymentSession.discount_percentage
			});
		}
	}
	
	// Otherwise, refresh the preview amounts using Stripe's Invoice Preview API
	try {
		const result = await refreshPreviewAmounts(
			paymentSession.customer_id,
			paymentSession.coupon_id,
			kysely,
			paymentSession.id // Pass as number, not string
		);
				// Return the result with prorated amounts from the refreshPreviewAmounts function
			return Response.json({
				pricingInfo: result.pricingInfo,
				monthlyAmount: result.monthlyAmount,
				annualAmount: result.annualAmount,
				// These come from the refreshPreviewAmounts function, not the database
				proratedMonthlyAmount: result.proratedMonthlyAmount,
				proratedAnnualAmount: result.proratedAnnualAmount,
				totalAmount: result.totalAmount,
				discountPercentage: paymentSession.discount_percentage
			});
	} catch (err) {
		console.error('Error refreshing preview amounts:', err);
		throw error(500, 'Failed to generate pricing preview');
	}
};
