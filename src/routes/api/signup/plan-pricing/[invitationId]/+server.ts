import * as Sentry from '@sentry/sveltekit';
import { error, json, type RequestHandler } from '@sveltejs/kit';
import dayjs from 'dayjs';
import isSameOrAfter from 'dayjs/plugin/isSameOrAfter';
import { env } from '$env/dynamic/private';
import { getKyselyClient } from '$lib/server/kysely';
import { generatePricingInfo, getPriceIds } from '$lib/server/pricingUtils';
import { stripeClient } from '$lib/server/stripe';

dayjs.extend(isSameOrAfter);

import * as v from 'valibot';

// Special migration code constant
const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ?? 'DHCDASHBOARD';

const couponCodeSchema = v.object({
	code: v.string()
});

async function getPricingDetails(
	userId: string,
	kysely: ReturnType<typeof getKyselyClient>,
	couponCode?: string
) {
	// Fetch base Stripe prices
	const { monthly, annual } = await getPriceIds(kysely);

	if (!monthly || !annual) {
		Sentry.captureMessage('Base prices not found for membership products', {
			extra: { userId }
		});
		throw error(500, 'Could not retrieve base product prices.');
	}

	// Get user profile for customer ID
	const userProfile = await kysely
		.selectFrom('user_profiles')
		.select(['customer_id'])
		.where('supabase_user_id', '=', userId)
		.executeTakeFirst();

	if (!userProfile?.customer_id) {
		throw error(500, 'User profile or Stripe customer ID not found');
	}

	const customerId = userProfile.customer_id;
	const nextMonth = dayjs().add(1, 'month').startOf('month').unix();
	const nextJanuary = dayjs().month(0).date(7).add(1, 'year').unix();

	try {
		// Get invoice previews for initial payment, next month, and next January
		const [initialInvoiceMonthly, initialInvoiceAnnual, nextMonthInvoice, nextJanuaryInvoice] =
			await Promise.all([
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [
							{
								price: monthly,
								quantity: 1
							}
						],
						billing_cycle_anchor: nextMonth
					},
					...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
				}),
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [
							{
								price: annual,
								quantity: 1
							}
						],
						billing_cycle_anchor: nextJanuary
					},
					...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
				}),
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [
							{
								price: monthly,
								quantity: 1
							}
						],
						start_date: nextMonth
					},
					...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
				}),
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [
							{
								price: annual,
								quantity: 1
							}
						],
						start_date: nextJanuary
					},
					...(couponCode ? { discounts: [{ promotion_code: couponCode }] } : {})
				})
			]);

		// Calculate total discount and discount percentage
		const totalDiscount =
			initialInvoiceMonthly.total_discount_amounts?.reduce(
				(sum, discount) => sum + discount.amount,
				0
			) ?? 0;
		const discountPercentage =
			totalDiscount > 0 ? Math.round((totalDiscount / initialInvoiceMonthly.subtotal) * 100) : 0;

		const monthlyDiscount =
			nextMonthInvoice?.total_discount_amounts?.reduce(
				(sum, discount) => sum + discount.amount,
				0
			) ?? 0;
		const annualDiscount =
			nextJanuaryInvoice?.total_discount_amounts?.reduce(
				(sum, discount) => sum + discount.amount,
				0
			) ?? 0;

		return {
			proratedPrice: initialInvoiceMonthly.amount_due + initialInvoiceAnnual.amount_due,
			monthlyFee: nextMonthInvoice.amount_due,
			annualFee: nextJanuaryInvoice.amount_due,
			discountPercentage,
			coupon: couponCode,
			discountedMonthlyFee: monthlyDiscount > 0 ? nextMonthInvoice.amount_due - monthlyDiscount : 0,
			discountedAnnualFee: annualDiscount > 0 ? nextJanuaryInvoice.amount_due - annualDiscount : 0,
			proratedAnnualPrice: initialInvoiceAnnual.amount_due,
			proratedMonthlyPrice: initialInvoiceMonthly.amount_due
		};
	} catch (err) {
		console.error(err);
		Sentry.captureException(err);
		throw error(500, 'Failed to get pricing details');
	}
}

export const POST: RequestHandler = async ({ request, params, platform }) => {
	try {
		const { invitationId } = params;
		if (!invitationId) {
			throw error(400, 'Missing invitation ID');
		}
		const kysely = getKyselyClient(platform?.env?.HYPERDRIVE);

		// 1. Fetch invitation to get user_id
		const invitation = await kysely
			.selectFrom('invitations')
			.select(['user_id'])
			.where('id', '=', invitationId)
			.where('status', '=', 'pending')
			.where('expires_at', '>', dayjs().toISOString())
			.executeTakeFirst();

		if (!invitation) {
			throw error(404, 'Invitation not found');
		}

		const body = await request.json();
		const couponCode = v.safeParse(couponCodeSchema, body);
		if (!couponCode.success) {
			Sentry.captureMessage('Invalid coupon code', {
				extra: {
					invitationId,
					body,
					couponCode: couponCode.issues
				}
			});
			throw error(400, 'Invalid coupon code');
		}

		// Handle no coupon code
		if (!couponCode.output?.code) {
			const pricingInfo = await getPricingDetails(invitation.user_id!, kysely);
			return json(generatePricingInfo(pricingInfo));
		}

		// Validate promotion code with Stripe
		const promotionCodes = await stripeClient.promotionCodes.list({
			active: true,
			code: couponCode.output.code,
			limit: 1
		});

		if (!promotionCodes.data.length) {
			throw error(400, 'Invalid or inactive promotion code');
		}

		// Handle migration code
		if (
			couponCode.output.code.toLowerCase().trim() === DASHBOARD_MIGRATION_CODE.toLowerCase().trim()
		) {
			const pricingInfo = await getPricingDetails(invitation.user_id!, kysely);

			// Override with migration pricing (proration = 0)
			const migrationPricing = {
				...pricingInfo,
				proratedPrice: 0,
				discountPercentage: 100,
				coupon: couponCode.output.code
			};

			return json(generatePricingInfo(migrationPricing));
		}
		const couponId =
			typeof promotionCodes.data[0].promotion.coupon === 'string' &&
			promotionCodes.data[0].promotion.coupon !== null
				? promotionCodes.data[0].promotion.coupon
				: promotionCodes.data[0].promotion.coupon !== null
					? promotionCodes.data[0].promotion.coupon.id
					: null;
		if (couponId === null) {
			throw error(400, 'Coupon not valid.');
		}
		const couponDetails = await stripeClient.coupons.retrieve(couponId, {
			expand: ['applies_to']
		});

		// Check if coupon type is supported
		if (couponDetails.duration === 'forever' && couponDetails.amount_off) {
			throw error(400, 'Forever coupons can only be percentage-based, not amount-based');
		}

		// Get pricing with discount applied
		const pricingInfo = await getPricingDetails(
			invitation.user_id!,
			kysely,
			promotionCodes.data[0].id
		);

		return json(generatePricingInfo(pricingInfo));
	} catch (err) {
		console.error(err);
		Sentry.captureException(err);
		if (err instanceof v.ValiError) {
			throw error(400, 'Invalid request body');
		}
		throw error(500, 'Failed to get pricing details');
	}
};

export const GET: RequestHandler = async ({ params, platform }) => {
	try {
		const { invitationId } = params;
		if (!invitationId) {
			throw error(400, 'Missing invitation ID');
		}
		const kysely = getKyselyClient(platform?.env?.HYPERDRIVE);

		// 1. Fetch invitation to get user_id
		const invitation = await kysely
			.selectFrom('invitations')
			.select(['user_id'])
			.where('id', '=', invitationId)
			.where('status', '=', 'pending')
			.where('expires_at', '>', dayjs().toISOString())
			.executeTakeFirst();

		if (!invitation) {
			throw error(404, 'Invitation not found');
		}

		const pricingInfo = await getPricingDetails(invitation.user_id!, kysely);

		return json(generatePricingInfo(pricingInfo));
	} catch (err) {
		Sentry.captureException(err);
		throw error(500, 'Failed to get pricing details');
	}
};
