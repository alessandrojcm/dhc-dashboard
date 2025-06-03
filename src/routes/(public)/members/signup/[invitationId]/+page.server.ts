import { memberSignupSchema } from "$lib/schemas/membersSignup";
import { error } from "@sveltejs/kit";
import { fail, message, superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { invariant } from "$lib/server/invariant";
import { stripeClient } from "$lib/server/stripe";
import { getKyselyClient } from "$lib/server/kysely";
import Stripe from "stripe";
import {
	completeMemberRegistration,
	getInvitationInfo,
	updateInvitationStatus,
} from "$lib/server/kyselyRPCFunctions";
import * as Sentry from "@sentry/sveltekit";
import { getNextBillingDates } from "$lib/server/pricingUtils";
import { getExistingPaymentSession } from "$lib/server/subscriptionCreation";
import type { Actions, PageServerLoad } from "./$types";
import { env } from "$env/dynamic/public";

const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ??
	"DHCDASHBOARD";

// need to normalize medical_conditions
export const load: PageServerLoad = async ({ params, platform, cookies }) => {
	const invitationId = params.invitationId;
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const isConfirmed = Boolean(
		cookies.get(`invite-confirmed-${invitationId}`),
	);

	try {
		// Get invitation data first (essential for page rendering)
		const { paymentSessionId, invitationData } = await kysely.transaction()
			.execute(async (trx) => {
				const invitationData = await getInvitationInfo(
					invitationId,
					trx,
				);
				const paymentSessionId = await trx.selectFrom("payment_sessions")
					.select("id").where("user_id", "=", invitationData.user_id)
					.executeTakeFirst();
				if (!paymentSessionId) {
					throw error(404, "No payment session found for this user.");
				}
				return {
					invitationData,
					paymentSessionId: paymentSessionId.id,
				};
			});

		if (!invitationData) {
			return error(404, "Invitation not found");
		}

		// Return essential data immediately, with pricing as a streamed promise
		return {
			form: await superValidate({}, valibot(memberSignupSchema), {
				errors: false,
			}),
			userData: {
				firstName: invitationData.first_name,
				lastName: invitationData.last_name,
				email: invitationData.email,
				dateOfBirth: new Date(invitationData.date_of_birth),
				phoneNumber: invitationData.phone_number,
				pronouns: invitationData.pronouns,
				gender: invitationData.gender,
				medicalConditions: invitationData.medical_conditions,
			},
			paymentSessionId,
			isConfirmed,
			insuranceFormLink: "",
			// These are needed for the page but can be calculated immediately
			...getNextBillingDates(),
		};
	} catch (err) {
		Sentry.captureException(err);
		error(404, {
			message: "Something went wrong",
		});
	}
};

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(memberSignupSchema));
		if (!form.valid) {
			return fail(422, {
				form,
			});
		}
		const kysely = getKyselyClient(event.platform.env.HYPERDRIVE);
		const confirmationToken: Stripe.ConfirmationToken = JSON.parse(
			form.data.stripeConfirmationToken,
		);

		return kysely
			.transaction()
			.execute(async (trx) => {
				const invitationData = await getInvitationInfo(
					event.params.invitationId,
					trx,
				);
				const paymentSession = await getExistingPaymentSession(
					invitationData.user_id,
					trx,
				);
				if (!paymentSession) {
					throw error(404, "No payment session found for this user.");
				}
				const {
					annual_payment_intent_id,
					monthly_payment_intent_id,
					customer_id,
					monthly_subscription_id,
					annual_subscription_id,
				} = paymentSession;

				// First get the invitation info and update its status to accepted
				if (invitationData && invitationData.invitation_id) {
					await updateInvitationStatus(
						invitationData.invitation_id,
						"accepted",
						trx,
					);
				}

				await Promise.all([
					completeMemberRegistration(
						{
							v_user_id: invitationData.user_id,
							p_next_of_kin_name: form.data.nextOfKin,
							p_next_of_kin_phone: form.data.nextOfKinNumber,
							p_insurance_form_submitted: true,
						},
						trx,
					),
					trx
						.updateTable("payment_sessions")
						.set({ is_used: true })
						.where(
							"monthly_payment_intent_id",
							"=",
							monthly_payment_intent_id,
						)
						.where(
							"annual_payment_intent_id",
							"=",
							annual_payment_intent_id,
						)
						.execute(),
					trx
						.updateTable("waitlist")
						.set({ status: "joined" })
						.where("email", "=", invitationData.email)
						.execute(),
				]);

				const intent = await stripeClient.setupIntents.create({
					confirm: true,
					customer: customer_id!,
					confirmation_token: confirmationToken.id,
					payment_method_types: ["sepa_debit"],
				});

				invariant(
					intent.status == "requires_payment_method",
					"payment_intent_requires_payment_method",
				);
				invariant(
					intent.payment_method == null,
					"payment_method_not_found",
				);
				const paymentMethodId =
					typeof intent.payment_method === "string"
						? intent.payment_method
						: (intent.payment_method! as Stripe.PaymentMethod).id;

				await Promise.all([
					stripeClient.subscriptions.update(monthly_subscription_id, {
						default_payment_method: paymentMethodId,
					}),
					stripeClient.subscriptions.update(annual_subscription_id, {
						default_payment_method: paymentMethodId,
					}),
					stripeClient.paymentIntents
						.confirm(monthly_payment_intent_id, {
							payment_method: paymentMethodId,
							mandate_data: {
								customer_acceptance: {
									type: "online",
									online: {
										ip_address: event.getClientAddress(),
										user_agent: event.request.headers.get(
											"user-agent",
										)!,
									},
								},
							},
						})
						.catch((err: Stripe.errors.StripeAPIError) => {
							if (
								paymentSession.coupon_id !==
									DASHBOARD_MIGRATION_CODE
							) {
								throw err;
							}
							Sentry.captureMessage(
								`Payment intent ${monthly_payment_intent_id} is in an unexpected state due to migration code ${DASHBOARD_MIGRATION_CODE}`,
							);
						}),
					stripeClient.paymentIntents
						.confirm(annual_payment_intent_id, {
							payment_method: paymentMethodId,
							mandate_data: {
								customer_acceptance: {
									type: "online",
									online: {
										ip_address: event.getClientAddress(),
										user_agent: event.request.headers.get(
											"user-agent",
										)!,
									},
								},
							},
						})
						.catch((err: Stripe.errors.StripeAPIError) => {
							if (
								paymentSession.coupon_id !==
									DASHBOARD_MIGRATION_CODE
							) {
								throw err;
							}
							Sentry.captureMessage(
								`Payment intent ${annual_payment_intent_id} is in an unexpected state due to migration code ${DASHBOARD_MIGRATION_CODE}`,
							);
						}),
				]);

				// Success! Delete the access token cookie
				event.cookies.delete("access-token", { path: "/" });
				return message(form, { paymentFailed: false });
			})
			.catch((err) => {
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
							errorMessage =
								"The payment method is not activated";
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

				return message(
					form,
					{ paymentFailed: true, error: errorMessage },
					{
						status: 400,
					},
				);
			});
	},
};
