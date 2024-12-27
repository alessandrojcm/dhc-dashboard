import { memberSignupSchema } from '$lib/schemas/membersSignup';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient.js';
import { error } from '@sveltejs/kit';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import { message, superValidate, fail } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { Actions, PageServerLoad } from './$types';
import { invariant } from '$lib/server/invariant';
import { stripeClient } from '$lib/server/stripe';
import { MEMEMBERSHIP_FEE_LOOKUP_NAME } from '$lib/server/constants';
import Dinero from 'dinero.js';
import { kysely } from '$lib/server/kysely';
import Stripe from 'stripe';
import { completeMemberRegistration, getMembershipInfo } from '$lib/server/kyselyRPCFunctions';

// need to normalize medical_conditions
export const load: PageServerLoad = async ({ parent }) => {
	const { userData } = await parent();
	try {
		const waitlistedMemberData = await kysely.transaction().execute(async (trx) => {
			const waitlistedMemberData = await getMembershipInfo(userData.id, trx);

			let customer_id = await trx
				.selectFrom('user_profiles')
				.select('customer_id')
				.where('supabase_user_id', '=', userData!.id)
				.executeTakeFirst()
				.then((r) => r?.customer_id);

			if (!customer_id) {
				customer_id = await stripeClient.customers
					.create({
						name: `${waitlistedMemberData.first_name} ${waitlistedMemberData.last_name}`,
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

			return { ...waitlistedMemberData, customer_id };
		});
		// we need to redirect to payment if the user has already signed up but has not paid
		const subscriptionPrice = await stripeClient.prices
			.list({
				lookup_keys: [MEMEMBERSHIP_FEE_LOOKUP_NAME]
			})
			.then((result) => result.data[0]);
		const subscription = await stripeClient.subscriptions.create({
			customer: waitlistedMemberData.customer_id!,
			items: [
				{
					price: subscriptionPrice!.id
				}
			],
			billing_cycle_anchor_config: {
				day_of_month: 1
			},
			payment_behavior: 'default_incomplete',
			payment_settings: {
				save_default_payment_method: 'on_subscription',
				payment_method_types: ['sepa_debit']
			},
			expand: ['latest_invoice.payment_intent']
		});
		return {
			form: await superValidate(
				{
					paymentIntentId: ((subscription.latest_invoice as Stripe.Invoice)!
						.payment_intent as Stripe.PaymentIntent)!.id
				},
				valibot(memberSignupSchema),
				{ errors: false }
			),
			userData: {
				firstName: waitlistedMemberData?.first_name,
				lastName: waitlistedMemberData?.last_name,
				email: userData.email,
				dateOfBirth: new Date(waitlistedMemberData!.date_of_birth!),
				phoneNumber: waitlistedMemberData?.phone_number,
				pronouns: waitlistedMemberData?.pronouns,
				gender: waitlistedMemberData?.gender,
				medicalConditions: waitlistedMemberData?.medical_conditions
			},
			insuranceFormLink: supabaseServiceClient
				.from('settings')
				.select('value')
				.eq('key', 'insurance_form_link')
				.limit(1)
				.single()
				.then((result) => result.data?.value),
			proratedPrice: Dinero({
				amount: ((subscription.latest_invoice as Stripe.Invoice)!
					.payment_intent as Stripe.PaymentIntent)!.amount!,
				currency: 'EUR'
			}).toJSON(),
			subscriptionAmount: Dinero({
				amount: subscription.plan.amount,
				currency: 'EUR'
			}).toJSON(),
			nextBillingDate: dayjs().add(1, 'month').startOf('month').toDate(),
			clientSecret: ((subscription.latest_invoice as Stripe.Invoice)!
				.payment_intent as Stripe.PaymentIntent)!.client_secret
		};
	} catch (err) {
		console.error(err);
		error(404, {
			message: 'Something went wrong'
		});
	}
};

export const actions: Actions = {
	default: async (event) => {
		const accessToken = event.url.searchParams.get('access_token');
		invariant(accessToken === null, `${event.url.pathname}?error_description=missing_access_token`);
		const tokenClaim = jwtDecode(accessToken!);
		invariant(
			dayjs.unix(tokenClaim.exp!).isBefore(dayjs()),
			`${event.url.pathname}?error_description=expired_access_token`
		);

		const form = await superValidate(event, valibot(memberSignupSchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		return await kysely
			.transaction()
			.execute(async (trx) => {
				await completeMemberRegistration(
					{
						v_user_id: tokenClaim.sub!,
						p_next_of_kin_name: form.data.nextOfKin,
						p_next_of_kin_phone: form.data.nextOfKinNumber,
						p_insurance_form_submitted: form.data.insuranceFormSubmitted
					},
					trx
				);

				const response = await stripeClient.paymentIntents.confirm(form.data.paymentIntentId, {
					confirmation_token: form.data.stripeConfirmationToken
				});
				return response.status;
			})
			.then((status) => {
				if (status === 'requires_action') {
					return message(form, { requiresAction: status === 'requires_action' });
				}
				return message(form, { paymentFailed: false });
			})
			.catch((err) => {
				console.log(err);
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
						case 'requires_payment_method':
							errorMessage = 'Please try again with a different payment method';
							break;
						case 'payment_intent_requires_action':
							return message(form, { requiresAction: true });
						case 'payment_intent_payment_failure':
							errorMessage = 'The payment failed. Please try again';
							break;
						case 'payment_intent_authentication_failure':
							errorMessage = 'The payment authentication failed. Please try again';
							break;
						case 'payment_intent_invalid':
							errorMessage = 'The payment information is invalid. Please try again';
							break;
						case 'payment_intent_unexpected_state':
							errorMessage = 'An unexpected error occurred with the payment. Please try again';
							break;
					}
				}

				return message(
					form,
					{
						paymentFailed: true,
						errorMessage
					},
					{
						status: 500
					}
				);
			});
	}
};
