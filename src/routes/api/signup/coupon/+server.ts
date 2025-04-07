import { invariant } from '$lib/server/invariant';
import { stripeClient } from '$lib/server/stripe';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import type { RequestHandler } from './$types';
import { kysely } from '$lib/server/kysely';

export const POST: RequestHandler = async ({ request, cookies }) => {
	const code = await request.json().then((data) => data.code);
	if (!code) {
		return Response.json({ message: 'Invalid request' }, { status: 400 });
	}
	const promotionCodes = await stripeClient.promotionCodes.list({
		active: true,
		code
	});
	if (promotionCodes.data.length > 0) {
		return Response.json({ message: 'Coupon code not valid.' }, { status: 400 });
	}

	const accessToken = cookies.get('access-token');
	invariant(accessToken === null, 'There has been an error with your signup.');
	const tokenClaim = jwtDecode(accessToken!);
	invariant(dayjs.unix(tokenClaim.exp!).isBefore(dayjs()), 'This invitation has expired');
	const userId = tokenClaim.sub!;

	const existingSession = await kysely
		.selectFrom('payment_sessions')
		.select([
			'monthly_subscription_id',
			'annual_subscription_id',
			'monthly_payment_intent_id',
			'annual_payment_intent_id',
			'monthly_amount',
			'annual_amount'
		])
		.where('user_id', '=', userId)
		.where('expires_at', '>', dayjs().toISOString())
		.where('is_used', '=', false)
		.leftJoin('user_profiles', 'user_profiles.supabase_user_id', 'payment_sessions.user_id')
		.select(['customer_id'])
		.executeTakeFirst();
	if (!existingSession) {
		return Response.json(
			{ message: 'No payment session found for this user.' },
			{
				status: 404
			}
		);
	}
	let errorCount = 0;
	await kysely.transaction().execute(async (trx) => {
		await Promise.all([
			stripeClient.subscriptions
				.update(existingSession.annual_subscription_id!, {
					discounts: [
						{
							promotion_code: code
						}
					]
				})
				.catch((err) => {
					errorCount++;
					console.error(`Discount code ${code} is not valid for annual subscription`, err);
				}),
			stripeClient.subscriptions
				.update(existingSession.monthly_subscription_id!, {
					discounts: [
						{
							promotion_code: code
						}
					]
				})
				.catch((err) => {
					errorCount++;
					console.error(`Discount code ${code} is not valid for monthly subscription`, err);
				})
		]);
		if (errorCount < 2) {
			await trx
				.updateTable('payment_sessions')
				.set({ coupon_id: code })
				.where('user_id', '=', userId)
				.execute();
		}
	});

	return errorCount === 2
		? Response.json({ message: 'Coupon code not valid.' }, { status: 400 })
		: Response.json({ message: 'Coupon applied' }, { status: 200 });
};
