import type { RequestHandler } from './$types';
import { getKyselyClient } from '$lib/server/kysely';
import { getExistingPaymentSession } from '$lib/server/subscriptionCreation';
import { error } from '@sveltejs/kit';
import type { SubscriptionWithPlan } from '$lib/types';
import { generatePricingInfo } from '$lib/server/pricingUtils';

export const GET: RequestHandler = async ({ params, platform }) => {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	// Get existing payment session data
	const userId = await kysely
		.selectFrom('invitations')
		.select('user_id')
		.where('id', '=', params.invitationId)
		.where('status', '=', 'pending')
		.executeTakeFirst();
	if (!userId || !userId?.user_id) {
		throw error(404, 'Invalid invitation');
	}
	const paymentSession = await getExistingPaymentSession(userId?.user_id, kysely);

	if (!paymentSession) {
		throw error(404, 'Invalid invitation');
	}

	// Create the pricing info directly from the payment session data
	// We need to create objects that match the structure expected by generatePricingInfo
	const monthlySubscription = {
		plan: {
			amount: paymentSession.monthly_amount
		}
	} as unknown as SubscriptionWithPlan;

	const annualSubscription = {
		plan: {
			amount: paymentSession.annual_amount
		}
	} as unknown as SubscriptionWithPlan;

	// Generate and return pricing info using only the payment session data
	return Response.json(
		generatePricingInfo(
			monthlySubscription,
			annualSubscription,
			paymentSession.monthly_amount,
			paymentSession.annual_amount,
			paymentSession
		)
	);
};
