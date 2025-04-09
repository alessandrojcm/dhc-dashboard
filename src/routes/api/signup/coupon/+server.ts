import { invariant } from '$lib/server/invariant';
import { stripeClient } from '$lib/server/stripe';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import type { RequestHandler } from './$types';
import { kysely } from '$lib/server/kysely';
import type Stripe from 'stripe';

export const POST: RequestHandler = async ({ request, cookies }) => {
	const code = await request.json().then((data) => data.code);
	if (!code) {
		return Response.json({ message: 'Invalid request' }, { status: 400 });
	}
	const promotionCodes = await stripeClient.promotionCodes.list({
		active: true,
		code
	});
	if (promotionCodes.data.length === 0) {
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
		const [updatedAnnualSubscription, updatedMonthlySubscription] = await Promise.all([
			stripeClient.subscriptions
				.update(existingSession.annual_subscription_id!, {
					discounts: [
						{
							promotion_code: promotionCodes.data[0].id
						}
					],
					expand: ['latest_invoice.payment_intent']
				})
				.catch((err) => {
					errorCount++;
					console.error(`Discount code ${code} is not valid for annual subscription`, err);
					return null;
				}),
			stripeClient.subscriptions
				.update(existingSession.monthly_subscription_id!, {
					discounts: [
						{
							promotion_code: promotionCodes.data[0].id
						}
					],
					expand: ['latest_invoice.payment_intent']
				})
				.catch((err) => {
					errorCount++;
					console.error(`Discount code ${code} is not valid for monthly subscription`, err);
					return null;
				})
		]);

		if (errorCount < 2) {
			// Extract updated amounts from the subscriptions
			let updatedAnnualAmount = existingSession.annual_amount;
			let updatedMonthlyAmount = existingSession.monthly_amount;

			if (updatedAnnualSubscription) {
				const annualInvoice = updatedAnnualSubscription.latest_invoice as Stripe.Invoice;
				if (annualInvoice && annualInvoice.payment_intent) {
					const paymentIntent = annualInvoice.payment_intent as Stripe.PaymentIntent;
					updatedAnnualAmount = paymentIntent.amount;
				}
			}

			if (updatedMonthlySubscription) {
				const monthlyInvoice = updatedMonthlySubscription.latest_invoice as Stripe.Invoice;
				if (monthlyInvoice && monthlyInvoice.payment_intent) {
					const paymentIntent = monthlyInvoice.payment_intent as Stripe.PaymentIntent;
					updatedMonthlyAmount = paymentIntent.amount;
				}
			}

			// Update the payment session with new amounts and coupon ID
			await trx
				.updateTable('payment_sessions')
				.set({
					coupon_id: code,
					annual_amount: updatedAnnualAmount,
					monthly_amount: updatedMonthlyAmount
				})
				.where('user_id', '=', userId)
				.execute();
		}
	});

	return errorCount === 2
		? Response.json({ message: 'Coupon code not valid.' }, { status: 400 })
		: Response.json({ message: 'Coupon applied' }, { status: 200 });
};
