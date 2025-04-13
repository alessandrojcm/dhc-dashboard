import { memberSignupSchema } from '$lib/schemas/membersSignup';
import { error } from '@sveltejs/kit';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import { fail, message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { Actions, PageServerLoad } from '../$types';
import { invariant } from '$lib/server/invariant';
import { stripeClient } from '$lib/server/stripe';
import { getPriceIds } from '$lib/server/priceManagement';
import { getKyselyClient } from '$lib/server/kysely';
import Stripe from 'stripe';
import {
	completeMemberRegistration,
	getInvitationInfo,
	updateInvitationStatus
} from '$lib/server/kyselyRPCFunctions';
import * as Sentry from '@sentry/sveltekit';
import type { KyselyDatabase, PlanPricing, SubscriptionWithPlan } from '$lib/types';
import { generatePricingInfo, getNextBillingDates } from '$lib/server/pricingUtils';
import {
	createSubscriptionSession,
	getExistingPaymentSession,
	validateExistingSession
} from '$lib/server/subscriptionCreation';
import type { Kysely } from 'kysely';

// need to normalize medical_conditions
export const load: PageServerLoad = async ({ parent, platform }) => {
	const { userData } = await parent();
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	try {
		// Get invitation data first (essential for page rendering)
		const invitationData = await kysely.transaction().execute(async (trx) => {
			// Get invitation info instead of waitlist info
			const invitationInfo = await getInvitationInfo(userData.id, trx);

			if (!invitationInfo || invitationInfo.status !== 'pending') {
				throw error(404, {
					message: 'Invalid invitation'
				});
			}

			let customer_id = await trx
				.selectFrom('user_profiles')
				.select(['customer_id'])
				.where('supabase_user_id', '=', userData!.id)
				.executeTakeFirst()
				.then((r) => r?.customer_id);

			if (!customer_id) {
				customer_id = await stripeClient.customers
					.create({
						name: `${invitationInfo.first_name} ${invitationInfo.last_name}`,
						email: userData.email,
						metadata: {
							user_uuid: userData.id
						}
					})
					.then((result) => result.id);

				await trx
					.updateTable('user_profiles')
					.set({
						customer_id
					})
					.where('supabase_user_id', '=', userData!.id)
					.execute();
			}

			return { ...invitationInfo, customer_id };
		});

		// Return essential data immediately, with pricing as a streamed promise
		return {
			form: await superValidate({}, valibot(memberSignupSchema), {
				errors: false
			}),
			userData: {
				firstName: invitationData.first_name,
				lastName: invitationData.last_name,
				email: userData.email,
				dateOfBirth: new Date(invitationData.date_of_birth),
				phoneNumber: invitationData.phone_number,
				pronouns: invitationData.pronouns,
				gender: invitationData.gender,
				medicalConditions: invitationData.medical_conditions
			},
			insuranceFormLink: '',
			// Stream these values
			streamed: {
				// This will be streamed to the client as it resolves
				pricingData: getPricingData(userData.id, invitationData.customer_id!, kysely).catch(
					(err) => {
						Sentry.captureException(err);
						throw error(500, 'Failed to retrieve pricing data.');
					}
				)
			},
			// These are needed for the page but can be calculated immediately
			...getNextBillingDates()
		};
	} catch (err) {
		Sentry.captureException(err);
		error(404, {
			message: 'Something went wrong'
		});
	}
};

// Helper function to get pricing data (will be streamed)
async function getPricingData(
	userId: string,
	customerId: string,
	kysely: Kysely<KyselyDatabase>
): Promise<PlanPricing> {
	// Get existing session and price IDs in parallel
	const [existingSessionData, priceIds] = await Promise.all([
		getExistingPaymentSession(userId, kysely),
		getPriceIds(kysely)
	]);

	let subscriptionData;

	if (existingSessionData) {
		// Validate existing session
		subscriptionData = await validateExistingSession(existingSessionData);
	}

	if (!existingSessionData || !subscriptionData?.valid) {
		// Create new subscriptions if no valid existing session
		subscriptionData = await createSubscriptionSession(userId, customerId, priceIds, kysely);
	}

	// Validate subscription data and throw error if invalid
	if (
		!subscriptionData ||
		![
			'annualPaymentIntent',
			'monthlyPaymentIntent',
			'monthlySubscription',
			'annualSubscription'
		].every((prop) => !!subscriptionData[prop]) ||
		subscriptionData.proratedMonthlyAmount === undefined ||
		subscriptionData.proratedAnnualAmount === undefined
	) {
		throw error(500, 'Failed to retrieve or create valid subscription session data.');
	}

	// Generate and return pricing info (TypeScript now knows these values exist)
	return generatePricingInfo(
		subscriptionData.monthlySubscription as unknown as SubscriptionWithPlan,
		subscriptionData.annualSubscription as unknown as SubscriptionWithPlan,
		subscriptionData.proratedMonthlyAmount as number,
		subscriptionData.proratedAnnualAmount as number,
		existingSessionData
	);
}

export const actions: Actions = {
	default: async (event) => {
		const accessToken = event.cookies.get('access-token');
		invariant(accessToken === null, 'There has been an error with your signup.');
		const tokenClaim = jwtDecode(accessToken!);
		invariant(dayjs.unix(tokenClaim.exp!).isBefore(dayjs()), 'This invitation has expired');

		const form = await superValidate(event, valibot(memberSignupSchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		const kysely = getKyselyClient(event.platform.env.HYPERDRIVE);

		const confirmationToken: Stripe.ConfirmationToken = JSON.parse(
			form.data.stripeConfirmationToken
		);

		return kysely
			.transaction()
			.execute(async (trx) => {
				const paymentSession = await getExistingPaymentSession(tokenClaim!.sub!, trx);
				if (!paymentSession) {
					throw error(404, 'No payment session found for this user.');
				}
				const {
					annual_subscription_id,
					monthly_subscription_id,
					annual_payment_intent_id,
					monthly_payment_intent_id,
					customer_id
				} = paymentSession;

				// First get the invitation info and update its status to accepted
				const invitationInfo = await getInvitationInfo(tokenClaim.sub!, trx);
				if (invitationInfo && invitationInfo.invitation_id) {
					await updateInvitationStatus(invitationInfo.invitation_id, 'accepted', trx);
				}

				// Then complete the member registration
				await completeMemberRegistration(
					{
						v_user_id: tokenClaim.sub!,
						p_next_of_kin_name: form.data.nextOfKin,
						p_next_of_kin_phone: form.data.nextOfKinNumber,
						p_insurance_form_submitted: true
					},
					trx
				);

				const intent = await stripeClient.setupIntents.create({
					confirm: true,
					customer: customer_id!,
					confirmation_token: confirmationToken.id,
					payment_method_types: ['sepa_debit']
				});

				invariant(
					intent.status == 'requires_payment_method',
					'payment_intent_requires_payment_method'
				);
				invariant(intent.payment_method == null, 'payment_method_not_found');
				const paymentMethodId =
					typeof intent.payment_method === 'string'
						? intent.payment_method
						: (intent.payment_method! as Stripe.PaymentMethod).id;

				await Promise.all([
					stripeClient.paymentIntents.confirm(monthly_payment_intent_id, {
						payment_method: paymentMethodId,
						mandate_data: {
							customer_acceptance: {
								type: 'online',
								online: {
									ip_address: event.getClientAddress(),
									user_agent: event.request.headers.get('user-agent')!
								}
							}
						}
					}),
					stripeClient.paymentIntents.confirm(annual_payment_intent_id, {
						payment_method: paymentMethodId,
						mandate_data: {
							customer_acceptance: {
								type: 'online',
								online: {
									ip_address: event.getClientAddress(),
									user_agent: event.request.headers.get('user-agent')!
								}
							}
						}
					})
				]);

				// After successful payment confirmation, mark the session as used
				await trx
					.updateTable('payment_sessions')
					.set({ is_used: true })
					.where('monthly_payment_intent_id', '=', `membershipSubscriptionPaymentIntendId`)
					.where('annual_payment_intent_id', '=', annual_payment_intent_id)
					.execute();

				// Success! Delete the access token cookie
				event.cookies.delete('access-token', { path: '/' });
				return message(form, { paymentFailed: false });
			})
			.catch((err) => {
				Sentry.captureException(err);
				let errorMessage = 'An unexpected error occurred';

				if (err instanceof Error && 'code' in err) {
					const stripeError = err as { code: string };
					switch (stripeError.code) {
						case 'charge_exceeds_source_limit':
						case 'charge_exceeds_transaction_limit':
							errorMessage = 'The payment amount exceeds the account payment volume limit';
							break;
						case 'charge_exceeds_weekly_limit':
							errorMessage = 'The payment amount exceeds the weekly transaction limit';
							break;
						case 'payment_intent_authentication_failure':
							errorMessage = 'The payment authentication failed';
							break;
						case 'payment_method_unactivated':
							errorMessage = 'The payment method is not activated';
							break;
						case 'payment_intent_payment_attempt_failed':
							errorMessage = 'The payment attempt failed';
							break;
						default:
							errorMessage = 'An error occurred with the payment processor';
							break;
					}
				}

				return message(
					form,
					{ paymentFailed: true, error: errorMessage },
					{
						status: 400
					}
				);
			});
	}
};
