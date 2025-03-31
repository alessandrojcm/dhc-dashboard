import type { RequestHandler } from '@sveltejs/kit';
import { kysely } from '$lib/server/kysely';
import { error, redirect } from '@sveltejs/kit';
import { stripeClient } from '$lib/server/stripe';

export const POST: RequestHandler = async (event) => {
	const memberId = event.params.memberId!;
	const customerId = await kysely
		.selectFrom('user_profiles')
		.select('customer_id')
		.where('supabase_user_id', '=', memberId)
		.limit(1)
		.execute()
		.then((result) => result[0]?.customer_id);

	if (!customerId) {
		return error(404, {
			message: 'Member not found'
		});
	}
	const billingPortalSession = await stripeClient.billingPortal.sessions.create({
		customer: customerId,
		return_url: `${event.url.origin}/dashboard/members/${memberId}`
	});
	return Response.json({
		portalURL: billingPortalSession.url
	});
};
