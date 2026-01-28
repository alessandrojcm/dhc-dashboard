import * as Sentry from "@sentry/sveltekit";
import { error } from "@sveltejs/kit";
import dayjs from "dayjs";
import { generatePricingInfo, getPriceIds } from "$lib/server/pricingUtils";
import { stripeClient } from "$lib/server/stripe";
import type { PlanPricing } from "$lib/types";
import type { Kysely, KyselyDatabase, Logger } from "../shared";

const DASHBOARD_MIGRATION_CODE = "DHCDASHBOARD";

export class PricingService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private migrationCode: string = DASHBOARD_MIGRATION_CODE,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	/**
	 * Creates Stripe invoice previews to calculate prorated and recurring subscription prices.
	 * This complex calculation involves multiple parallel API calls with different billing anchors.
	 */
	private async getPricingDetails(
		userId: string,
		couponCode?: string,
	): Promise<{
		proratedPrice: number;
		monthlyFee: number;
		annualFee: number;
		discountPercentage: number;
		coupon?: string;
		discountedMonthlyFee: number;
		discountedAnnualFee: number;
		proratedAnnualPrice: number;
		proratedMonthlyPrice: number;
	}> {
		const { monthly, annual } = await getPriceIds(this.kysely);

		if (!monthly || !annual) {
			Sentry.captureMessage("Base prices not found for membership products", {
				extra: { userId },
			});
			throw error(500, "Could not retrieve base product prices.");
		}

		const userProfile = await this.kysely
			.selectFrom("user_profiles")
			.select(["customer_id"])
			.where("supabase_user_id", "=", userId)
			.executeTakeFirst();

		if (!userProfile?.customer_id) {
			throw error(500, "User profile or Stripe customer ID not found");
		}

		const customerId = userProfile.customer_id;
		const nextMonth = dayjs().add(1, "month").startOf("month").unix();
		const nextJanuary = dayjs().month(0).date(6).add(1, "year").unix();

		try {
			// Invoice previews: initial (prorated), next month recurring, next January recurring
			const [
				initialInvoiceMonthly,
				initialInvoiceAnnual,
				nextMonthInvoice,
				nextJanuaryInvoice,
			] = await Promise.all([
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [{ price: monthly, quantity: 1 }],
						billing_cycle_anchor: nextMonth,
					},
					...(couponCode
						? { discounts: [{ promotion_code: couponCode }] }
						: {}),
				}),
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [{ price: annual, quantity: 1 }],
						billing_cycle_anchor: nextJanuary,
					},
					...(couponCode
						? { discounts: [{ promotion_code: couponCode }] }
						: {}),
				}),
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [{ price: monthly, quantity: 1 }],
						start_date: nextMonth,
					},
					...(couponCode
						? { discounts: [{ promotion_code: couponCode }] }
						: {}),
				}),
				stripeClient.invoices.createPreview({
					customer: customerId,
					subscription_details: {
						items: [{ price: annual, quantity: 1 }],
						start_date: nextJanuary,
					},
					...(couponCode
						? { discounts: [{ promotion_code: couponCode }] }
						: {}),
				}),
			]);

			const monthlyDiscount =
				nextMonthInvoice?.total_discount_amounts?.reduce(
					(sum, discount) => sum + discount.amount,
					0,
				) ?? 0;
			const annualDiscount =
				nextJanuaryInvoice?.total_discount_amounts?.reduce(
					(sum, discount) => sum + discount.amount,
					0,
				) ?? 0;

			const initialMonthlyDiscount =
				initialInvoiceMonthly.total_discount_amounts?.reduce(
					(sum, discount) => sum + discount.amount,
					0,
				) ?? 0;

			let discountPercentage = 0;
			if (initialMonthlyDiscount > 0) {
				discountPercentage = Math.round(
					(initialMonthlyDiscount / initialInvoiceMonthly.subtotal) * 100,
				);
			} else if (monthlyDiscount > 0) {
				discountPercentage = Math.round(
					(monthlyDiscount / nextMonthInvoice.subtotal) * 100,
				);
			}

			return {
				proratedPrice:
					initialInvoiceMonthly.amount_due + initialInvoiceAnnual.amount_due,
				monthlyFee: nextMonthInvoice.subtotal,
				annualFee: nextJanuaryInvoice.subtotal,
				discountPercentage,
				coupon: couponCode,
				discountedMonthlyFee:
					monthlyDiscount > 0 ? nextMonthInvoice.amount_due : 0,
				discountedAnnualFee:
					annualDiscount > 0 ? nextJanuaryInvoice.amount_due : 0,
				proratedAnnualPrice: initialInvoiceAnnual.amount_due,
				proratedMonthlyPrice: initialInvoiceMonthly.amount_due,
			};
		} catch (err) {
			this.logger.error("Failed to get pricing details", {
				error: err,
				userId,
			});
			Sentry.captureException(err);
			throw error(500, "Failed to get pricing details");
		}
	}

	async getPricingForInvitation(invitationId: string): Promise<PlanPricing> {
		this.logger.info("Fetching pricing for invitation", { invitationId });

		const invitation = await this.kysely
			.selectFrom("invitations")
			.select(["user_id"])
			.where("id", "=", invitationId)
			.where("status", "=", "pending")
			.where("expires_at", ">", dayjs().toISOString())
			.executeTakeFirst();

		if (!invitation) {
			throw error(404, "Invitation not found");
		}

		const pricingInfo = await this.getPricingDetails(invitation.user_id!);
		return generatePricingInfo(pricingInfo);
	}

	async getPricingWithCoupon(
		invitationId: string,
		couponCode: string,
	): Promise<PlanPricing> {
		this.logger.info("Fetching pricing with coupon", {
			invitationId,
			couponCode,
		});

		const invitation = await this.kysely
			.selectFrom("invitations")
			.select(["user_id"])
			.where("id", "=", invitationId)
			.where("status", "=", "pending")
			.where("expires_at", ">", dayjs().toISOString())
			.executeTakeFirst();

		if (!invitation) {
			throw error(404, "Invitation not found");
		}

		if (!couponCode?.trim()) {
			const pricingInfo = await this.getPricingDetails(invitation.user_id!);
			return generatePricingInfo(pricingInfo);
		}

		const promotionCodes = await stripeClient.promotionCodes.list({
			active: true,
			code: couponCode,
			limit: 1,
		});

		if (!promotionCodes.data.length) {
			throw error(400, "Invalid or inactive promotion code");
		}

		const promotionCode = promotionCodes.data[0];

		if (
			couponCode.toLowerCase().trim() ===
			this.migrationCode.toLowerCase().trim()
		) {
			const pricingInfo = await this.getPricingDetails(invitation.user_id!);
			return generatePricingInfo({
				...pricingInfo,
				proratedPrice: 0,
				discountPercentage: 100,
				coupon: couponCode,
			});
		}

		const couponId = promotionCode.promotion.coupon;
		if (typeof couponId !== "string")
			throw error(400, "Invalid or inactive promotion code.");

		const couponDetails = await stripeClient.coupons.retrieve(couponId, {
			expand: ["applies_to"],
		});

		if (couponDetails.duration === "forever" && couponDetails.amount_off) {
			throw error(
				400,
				"Forever coupons can only be percentage-based, not amount-based",
			);
		}

		const pricingInfo = await this.getPricingDetails(
			invitation.user_id!,
			promotionCode.id,
		);

		if (couponDetails.duration === "once" && couponDetails.percent_off) {
			return generatePricingInfo({
				...pricingInfo,
				discountPercentage: couponDetails.percent_off,
				discountedMonthlyFee: 0,
				discountedAnnualFee: 0,
			});
		}

		return generatePricingInfo(pricingInfo);
	}
}
