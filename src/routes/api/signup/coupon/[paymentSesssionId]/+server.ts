import { stripeClient } from '$lib/server/stripe';
import dayjs from 'dayjs';
import type { RequestHandler } from './$types';
import type Stripe from 'stripe';
import { getKyselyClient } from '$lib/server/kysely';
import * as Sentry from '@sentry/sveltekit';
import { env } from '$env/dynamic/public';
import type { Database } from '$database';

const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ?? 'DHCDASHBOARD';

export const POST: RequestHandler = async ({ request, params, cookies, platform }) => {
	const code = await request.json<{ code: string }>().then((data) => data?.code);
	if (!code) {
		return Response.json({ message: 'Invalid request' }, { status: 400 });
	}

	// Check if this is the special migration code
	const isMigrationCode = code === DASHBOARD_MIGRATION_CODE;
	// If it's not the migration code, verify it's a valid promotion code
	const kysely = getKyselyClient(platform!.env.HYPERDRIVE);
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
		.where('payment_sessions.id', '=', Number(params.paymentSesssionId))
		.where('payment_sessions.expires_at', '>', dayjs().toISOString())
		.where('payment_sessions.is_used', '=', false)
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
	let promotionCodes: Stripe.ApiList<Stripe.PromotionCode> | null = null;

	// If it's not a migration code, we need the promotion code data for later

	promotionCodes = await stripeClient.promotionCodes.list({
		active: true,
		code
	});

	await kysely.transaction().execute(async (trx) => {
		// Handle migration code and regular coupon code differently
		if (isMigrationCode) {
			// For migration code, fetch the subscriptions without applying coupon
			const [annualSubscription, monthlySubscription] = await Promise.all([
				existingSession.annual_subscription_id
					? stripeClient.subscriptions.retrieve(existingSession.annual_subscription_id, {
							expand: ['latest_invoice.payments']
						})
					: Promise.reject(new Error('No annual subscription ID')),
				existingSession.monthly_subscription_id
					? stripeClient.subscriptions.retrieve(existingSession.monthly_subscription_id, {
							expand: ['latest_invoice.payments']
						})
					: Promise.reject(new Error('No monthly subscription ID'))
			]);

			// Process annual subscription
			if (annualSubscription && annualSubscription.latest_invoice) {
				const annualInvoice = annualSubscription.latest_invoice as Stripe.Invoice;
				if (annualInvoice.amount_due > 0 && annualInvoice.lines.data.length > 0) {
					try {
						await stripeClient.creditNotes.create({
							invoice: annualInvoice.id!,
							amount: annualInvoice.amount_due,
							reason: 'order_change',
							memo: 'Migration discount applied for existing customer'
						});
					} catch (err) {
						Sentry.captureException(err, {
							extra: {
								message: `Failed to create credit note for annual subscription invoice ${annualInvoice.id}`,
								invoiceId: annualInvoice.id
							}
						});
					}
				}
			}

			// Process monthly subscription
			if (monthlySubscription && monthlySubscription.latest_invoice) {
				const monthlyInvoice = monthlySubscription.latest_invoice as Stripe.Invoice;
				if (monthlyInvoice.amount_due > 0 && monthlyInvoice.lines.data.length > 0) {
					try {
						await stripeClient.creditNotes.create({
							invoice: monthlyInvoice.id!,
							amount: monthlyInvoice.amount_due,
							reason: 'order_change',
							memo: 'Migration discount applied for existing customer'
						});
					} catch (err) {
						Sentry.captureException(err, {
							extra: {
								message: `Failed to create credit note for monthly subscription invoice ${monthlyInvoice.id}`,
								invoiceId: monthlyInvoice.id
							}
						});
					}
				}
			}

			// Update payment session with credit note information
			const updateFields: Partial<Database['public']['Tables']['payment_sessions']['Row']> = {
				coupon_id: code,
				total_amount: 0 // Set to 0 since we're crediting the full amount,
			};

			if (annualSubscription) {
				const annualInvoice = annualSubscription.latest_invoice as Stripe.Invoice;
				if (annualInvoice && annualInvoice.payments?.data?.[0]?.payment) {
					const paymentIntent = annualInvoice.payments?.data?.[0]?.payment!;
					// Get the prorated amount from the payment intent
					updateFields.annual_payment_intent_id = paymentIntent.payment_intent! as string;
				}
			}

			if (monthlySubscription) {
				const monthlyInvoice = monthlySubscription.latest_invoice as Stripe.Invoice;
				if (monthlyInvoice && monthlyInvoice.payments?.data?.[0]?.payment) {
					const paymentIntent = monthlyInvoice.payments?.data?.[0]?.payment!;
					// Get the prorated amount from the payment intent
					updateFields.monthly_payment_intent_id = paymentIntent.payment_intent! as string;
				}
			}

			// Update the payment session
			await trx
				.updateTable('payment_sessions')
				.set(updateFields)
				.where('id', '=', Number(params.paymentSesssionId))
				.execute();
		} else {
			// Regular coupon code flow
			if (!promotionCodes || promotionCodes.data.length === 0) {
				errorCount = 2;
				return;
			}

			const [updatedAnnualSubscription, updatedMonthlySubscription] = await Promise.all([
				stripeClient.subscriptions
					.update(existingSession.annual_subscription_id!, {
						discounts: [
							{
								promotion_code: promotionCodes!.data[0].id
							}
						],
						expand: ['latest_invoice.payments']
					})
					.catch((err) => {
						errorCount++;
						Sentry.captureMessage(
							`Discount code ${code} is not valid for annual subscription ${err}`,
							'error'
						);
						return null;
					}),
				stripeClient.subscriptions
					.update(existingSession.monthly_subscription_id!, {
						discounts: [
							{
								promotion_code: promotionCodes!.data[0].id
							}
						],
						expand: ['latest_invoice.payments']
					})
					.catch((err) => {
						errorCount++;
						Sentry.captureMessage(
							`Discount code ${code} is not valid for monthly subscription ${err}`,
							'error'
						);
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
				const couponDetails = await stripeClient.coupons.retrieve(
					promotionCodes!.data[0].coupon.id
				);

				// Check if this is a 'forever' duration coupon with 'amount_off' which is no longer supported in Basil
				if (couponDetails.duration === 'forever' && couponDetails.amount_off) {
					return Response.json(
						{
							message: 'This coupon type is no longer supported. Please contact support.'
						},
						{ status: 400 }
					);
				}

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
					if (annualInvoice && annualInvoice.payments?.data?.[0]?.payment) {
						const paymentIntent = annualInvoice.payments?.data?.[0]?.payment!;
						// Get the prorated amount from the payment intent
						proratedAnnualAmount = annualInvoice.amount_due! as number;
						updatedAnnualPaymentIntentId = paymentIntent.payment_intent! as string;
					}
				}

				if (updatedMonthlySubscription) {
					const monthlyInvoice = updatedMonthlySubscription.latest_invoice as Stripe.Invoice;
					if (monthlyInvoice && monthlyInvoice.payments?.data?.[0]?.payment) {
						const paymentIntent = monthlyInvoice.payments?.data?.[0]?.payment!;
						// Get the prorated amount from the payment intent
						proratedMonthlyAmount = monthlyInvoice.amount_due! as number;
						updatedMonthlyPaymentIntentId = paymentIntent.payment_intent! as string;
					}
				}

				// Create an object to store the fields to update
				const updateFields: Record<string, string | number | boolean> = {
					coupon_id: code,
					// Don't update monthly_amount and annual_amount as they should reflect the plan amounts
					// Update the payment intent IDs as they change when a coupon is applied
					annual_payment_intent_id: updatedAnnualPaymentIntentId,
					monthly_payment_intent_id: updatedMonthlyPaymentIntentId,
					// Update the total amount (what user will pay now) with the prorated amounts
					total_amount: proratedMonthlyAmount + proratedAnnualAmount,
					// Store the discounted amounts for recurring payments
					discounted_monthly_amount: discountedMonthlyAmount ?? 0,
					discounted_annual_amount: discountedAnnualAmount ?? 0
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
					.where('id', '=', Number(params.paymentSesssionId))
					.execute();
			}
		}
	});

	return errorCount === 2 && !isMigrationCode
		? Response.json({ message: 'Coupon code not valid.' }, { status: 400 })
		: Response.json({ message: 'Coupon applied' }, { status: 200 });
};
