import { invariant } from '$lib/server/invariant';
import { stripeClient } from '$lib/server/stripe';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import type { RequestHandler } from './$types';
import { kysely } from '$lib/server/kysely';
import type Stripe from 'stripe';
import { STRIPE_SIGNUP_INFO } from '$lib/server/constants';

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
			// Extract payment intent IDs and amounts from the subscriptions
			let updatedAnnualPaymentIntentId = existingSession.annual_payment_intent_id;
			let updatedMonthlyPaymentIntentId = existingSession.monthly_payment_intent_id;
			let proratedAnnualAmount = 0;
			let proratedMonthlyAmount = 0;
			let discountPercentage = 0;
			let discountedMonthlyAmount: number | null = existingSession.monthly_amount;
			let discountedAnnualAmount: number | null = existingSession.annual_amount;

			// Get the coupon details to calculate discounted amounts
			const couponDetails = await stripeClient.coupons.retrieve(promotionCodes.data[0].coupon.id);

			// Handle different coupon durations
			// If duration is 'once', it only applies to the first payment and doesn't affect recurring plan pricing
			if (couponDetails.duration === 'once') {
				// For 'once' coupons, set discounted amounts to null to indicate they don't apply to recurring payments
				discountedMonthlyAmount = null;
				discountedAnnualAmount = null;

				// Calculate discount percentage for display purposes
				if (couponDetails.percent_off) {
					discountPercentage = couponDetails.percent_off;
				} else if (couponDetails.amount_off) {
					const totalAmount = existingSession.monthly_amount + existingSession.annual_amount;
					discountPercentage = Math.round((couponDetails.amount_off / totalAmount) * 100);
				}
			} else {
				// For recurring coupons (forever, repeating), calculate discounted amounts
				if (couponDetails.percent_off) {
					// Percentage discount
					discountPercentage = couponDetails.percent_off;
					const percentOff = discountPercentage / 100;
					discountedMonthlyAmount = Math.round(existingSession.monthly_amount * (1 - percentOff));
					discountedAnnualAmount = Math.round(existingSession.annual_amount * (1 - percentOff));
				} else if (couponDetails.amount_off) {
					// Fixed amount discount - distribute proportionally
					const totalAmount = existingSession.monthly_amount + existingSession.annual_amount;
					const amountOff = couponDetails.amount_off;

					// Calculate an equivalent percentage for display
					discountPercentage = Math.round((amountOff / totalAmount) * 100);

					// Distribute the discount proportionally
					const monthlyProportion = existingSession.monthly_amount / totalAmount;
					const annualProportion = existingSession.annual_amount / totalAmount;

					discountedMonthlyAmount = Math.max(
						0,
						existingSession.monthly_amount - Math.round(amountOff * monthlyProportion)
					);
					discountedAnnualAmount = Math.max(
						0,
						existingSession.annual_amount - Math.round(amountOff * annualProportion)
					);
				}
			}

			if (updatedAnnualSubscription) {
				const annualInvoice = updatedAnnualSubscription.latest_invoice as Stripe.Invoice;
				if (annualInvoice && annualInvoice.payment_intent) {
					const paymentIntent = annualInvoice.payment_intent as Stripe.PaymentIntent;
					// Get the prorated amount from the payment intent
					proratedAnnualAmount = paymentIntent.amount;
					updatedAnnualPaymentIntentId = paymentIntent.id;
				}
			}

			if (updatedMonthlySubscription) {
				const monthlyInvoice = updatedMonthlySubscription.latest_invoice as Stripe.Invoice;
				if (monthlyInvoice && monthlyInvoice.payment_intent) {
					const paymentIntent = monthlyInvoice.payment_intent as Stripe.PaymentIntent;
					// Get the prorated amount from the payment intent
					proratedMonthlyAmount = paymentIntent.amount;
					updatedMonthlyPaymentIntentId = paymentIntent.id;
				}
			}

			// Create an object to store the fields to update
			const updateFields: Record<string, string> = {
				coupon_id: code,
				// Don't update monthly_amount and annual_amount as they should reflect the plan amounts
				// Update the payment intent IDs as they change when a coupon is applied
				annual_payment_intent_id: updatedAnnualPaymentIntentId,
				monthly_payment_intent_id: updatedMonthlyPaymentIntentId,
				// Update the total amount (what user will pay now) with the prorated amounts
				total_amount: proratedMonthlyAmount + proratedAnnualAmount,
				// Store the discounted amounts for recurring payments
				discounted_monthly_amount: discountedMonthlyAmount,
				discounted_annual_amount: discountedAnnualAmount
			};

			// Store the discount percentage for both one-time and permanent discounts
			if (discountPercentage > 0) {
				updateFields.discount_percentage = discountPercentage;
			}

			// Update the payment session with new payment intent IDs, coupon ID, and discounted amounts
			// Keep the original plan amounts (monthly_amount and annual_amount)
			// Only update the total_amount with the new prorated amounts
			await trx
				.updateTable('payment_sessions')
				.set(updateFields)
				.where('user_id', '=', userId)
				.execute();
		}
	});

	return errorCount === 2
		? Response.json({ message: 'Coupon code not valid.' }, { status: 400 })
		: Response.json({ message: 'Coupon applied' }, { status: 200 });
};
