import { form, getRequestEvent } from "$app/server";
import { error } from "@sveltejs/kit";
import * as Sentry from "@sentry/sveltekit";
import type Stripe from "stripe";
import { inviteValidationSchema } from "$lib/schemas/inviteValidationSchema";
import { memberSignupSchema } from "$lib/schemas/membersSignup";
import { invariant } from "$lib/server/invariant";
import { getKyselyClient } from "$lib/server/kysely";
import { getPriceIds } from "$lib/server/pricingUtils";
import { createInvitationService } from "$lib/server/services/invitations";
import { stripeClient } from "$lib/server/stripe";
import { env } from "$env/dynamic/public";
import { dev } from "$app/environment";

const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ??
	"DHCDASHBOARD";

/**
 * Validates an invitation by checking email and date of birth
 */
export const validateInvitation = form(inviteValidationSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	if (!invitationId) {
		throw new Error("Invitation ID is required");
	}

	const invitationService = createInvitationService(event.platform!);
	const isValid = await invitationService.validateCredentials(
		invitationId,
		data.email,
		data.dateOfBirth,
	);

	if (!isValid) {
		return { success: false, verified: false };
	}

	event.cookies.set(`invite-confirmed-${invitationId}`, "true", {
		expires: new Date(Date.now() + 60 * 60 * 24 * 30),
		path: "/",
		httpOnly: !dev,
		secure: !dev,
		sameSite: "lax",
	});
	return { success: true, verified: true };
});

/**
 * Processes payment for member signup
 */
export const processPayment = form(memberSignupSchema, async (data) => {
	const event = getRequestEvent();
	const invitationId = event.params.invitationId;

	if (!invitationId) {
		throw error(400, "Invitation ID is required");
	}

	const kysely = getKyselyClient(event.platform?.env.HYPERDRIVE);
	const confirmationToken: Stripe.ConfirmationToken = JSON.parse(
		data.stripeConfirmationToken,
	);
	const invitationService = createInvitationService(event.platform!);

	try {
		return await kysely.transaction().execute(async (trx) => {
			// Process invitation acceptance (handles status update, registration, waitlist)
			const invitationData = await invitationService
				.processInvitationAcceptance(
					trx,
					invitationId,
					data.nextOfKin,
					data.nextOfKinNumber,
				);

			// Get customer ID
			const customerId = await trx
				.selectFrom("user_profiles")
				.select("customer_id")
				.where("supabase_user_id", "=", invitationData.user_id)
				.executeTakeFirst();

			if (!customerId) {
				throw error(404, "No customer ID found for this user.");
			}

			const intent = await stripeClient.setupIntents.create({
				confirm: true,
				customer: customerId.customer_id!,
				confirmation_token: confirmationToken.id,
				payment_method_types: ["sepa_debit"],
			});

			invariant(
				intent.status === "requires_payment_method",
				"payment_intent_requires_payment_method",
			);
			invariant(
				intent.payment_method == null,
				"payment_method_not_found",
			);

			const paymentMethodId = typeof intent.payment_method === "string"
				? intent.payment_method
				: (intent.payment_method! as Stripe.PaymentMethod).id;

			// Fetch base Stripe prices
			const { monthly, annual } = await getPriceIds(kysely);

			if (!monthly || !annual) {
				Sentry.captureMessage(
					"Base prices not found for membership products",
					{
						extra: { userId: invitationData.user_id },
					},
				);
				throw error(500, "Could not retrieve base product prices.");
			}

			let isMigration = false;
			let promotionCodeId: string | undefined;
			if (data.couponCode) {
				const promotionCodes = await stripeClient.promotionCodes.list({
					active: true,
					code: data.couponCode,
					limit: 1,
				});
				if (!promotionCodes.data.length) {
					throw error(400, "Invalid or inactive promotion code");
				}
				if (
					data.couponCode.toLowerCase().trim() ===
						DASHBOARD_MIGRATION_CODE.toLowerCase().trim()
				) {
					isMigration = true;
				} else {
					promotionCodeId = promotionCodes.data[0].id;
				}
			}

			await Promise.all([
				stripeClient.subscriptions
					.create({
						customer: customerId.customer_id!,
						items: [{ price: monthly }],
						billing_cycle_anchor_config: {
							day_of_month: 1,
						},
						payment_behavior: "default_incomplete",
						payment_settings: {
							payment_method_types: ["sepa_debit"],
						},
						expand: ["latest_invoice.payments"],
						collection_method: "charge_automatically",
						default_payment_method: paymentMethodId,
						discounts: !isMigration && promotionCodeId
							? [{ promotion_code: promotionCodeId }]
							: undefined,
					})
					.then(async (subscription) => {
						if (
							(subscription.latest_invoice as Stripe.Invoice)
								.payments?.data.length === 0
						) {
							return;
						}
						if (isMigration) {
							return stripeClient.creditNotes.create({
								invoice:
									(subscription
										.latest_invoice as Stripe.Invoice).id!,
								amount:
									(subscription
										.latest_invoice as Stripe.Invoice)
										.amount_due,
							});
						}
						return stripeClient.paymentIntents.confirm(
							(subscription.latest_invoice as Stripe.Invoice)
								.payments?.data[0].payment
								.payment_intent as string,
							{
								payment_method: paymentMethodId,
								mandate_data: {
									customer_acceptance: {
										type: "online",
										online: {
											ip_address: event
												.getClientAddress(),
											user_agent: event.request.headers
												.get("user-agent")!,
										},
									},
								},
							},
						);
					}),
				stripeClient.subscriptions
					.create({
						customer: customerId.customer_id!,
						items: [{ price: annual }],
						payment_behavior: "default_incomplete",
						payment_settings: {
							payment_method_types: ["sepa_debit"],
						},
						billing_cycle_anchor_config: {
							month: 1,
							day_of_month: 7,
						},
						expand: ["latest_invoice.payments"],
						collection_method: "charge_automatically",
						default_payment_method: paymentMethodId,
						discounts: !isMigration && promotionCodeId
							? [{ promotion_code: promotionCodeId }]
							: undefined,
					})
					.then(async (subscription) => {
						if (
							(subscription.latest_invoice as Stripe.Invoice)
								.payments?.data.length === 0
						) {
							return;
						}
						if (isMigration) {
							return stripeClient.creditNotes.create({
								invoice:
									(subscription
										.latest_invoice as Stripe.Invoice).id!,
								amount:
									(subscription
										.latest_invoice as Stripe.Invoice)
										.amount_due,
							});
						}
						return stripeClient.paymentIntents.confirm(
							(subscription.latest_invoice as Stripe.Invoice)
								.payments?.data[0].payment
								.payment_intent as string,
							{
								payment_method: paymentMethodId,
								mandate_data: {
									customer_acceptance: {
										type: "online",
										online: {
											ip_address: event
												.getClientAddress(),
											user_agent: event.request.headers
												.get("user-agent")!,
										},
									},
								},
							},
						);
					}),
			]);

			// Success! Delete the access token cookie
			event.cookies.delete("access-token", { path: "/" });
			return { paymentFailed: false };
		});
	} catch (err) {
		Sentry.captureException(err);
		let errorMessage = "An unexpected error occurred";

		if (err instanceof Error && "code" in err) {
			const stripeError = err as { code: string };
			switch (stripeError.code) {
				case "charge_exceeds_source_limit":
				case "charge_exceeds_transaction_limit":
					errorMessage =
						"The payment amount exceeds the account payment volume limit";
					break;
				case "charge_exceeds_weekly_limit":
					errorMessage =
						"The payment amount exceeds the weekly transaction limit";
					break;
				case "payment_intent_authentication_failure":
					errorMessage = "The payment authentication failed";
					break;
				case "payment_method_unactivated":
					errorMessage = "The payment method is not activated";
					break;
				case "payment_intent_payment_attempt_failed":
					errorMessage = "The payment attempt failed";
					break;
				default:
					errorMessage =
						"An error occurred with the payment processor";
					break;
			}
		}

		return { paymentFailed: true, error: errorMessage };
	}
});
