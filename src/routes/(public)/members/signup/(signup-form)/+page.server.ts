import { memberSignupSchema } from '$lib/schemas/membersSignup';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient.js';
import { error } from '@sveltejs/kit';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import { message, superValidate, fail } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { Actions, PageServerLoad } from '../$types';
import { invariant } from '$lib/server/invariant';
import { stripeClient } from '$lib/server/stripe';
import { MEMBERSHIP_FEE_LOOKUP_NAME, ANNUAL_FEE_LOOKUP } from '$lib/server/constants';
import Dinero from 'dinero.js';
import { kysely } from '$lib/server/kysely';
import Stripe from 'stripe';
import { completeMemberRegistration, getMembershipInfo } from '$lib/server/kyselyRPCFunctions';

type StripePaymentInfo = {
	customerId: string;
	annualSubscriptionPaymentIntendId: string;
	membershipSubscriptionPaymentIntendId: string;
};

// need to normalize medical_conditions
export const load: PageServerLoad = async ({ parent, cookies }) => {
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

		const [subscriptionPrice, annualFeePrice] = await Promise.all([
			stripeClient.prices
				.list({
					lookup_keys: [MEMBERSHIP_FEE_LOOKUP_NAME]
				})
				.then((result) => result.data[0]),
			stripeClient.prices
				.list({
					lookup_keys: [ANNUAL_FEE_LOOKUP]
				})
				.then((result) => result.data[0])
		]);

		const [monthlySubscription, annualSubscription] = await Promise.all([
			stripeClient.subscriptions.create({
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
					payment_method_types: ['sepa_debit']
				},
				expand: ['latest_invoice.payment_intent'],
				collection_method: 'charge_automatically'
			}),
			stripeClient.subscriptions.create({
				customer: waitlistedMemberData.customer_id!,
				items: [
					{
						price: annualFeePrice!.id
					}
				],
				payment_behavior: 'default_incomplete',
				payment_settings: {
					payment_method_types: ['sepa_debit']
				},
				billing_cycle_anchor_config: {
					month: 1,
					day_of_month: 7
				},
				expand: ['latest_invoice.payment_intent'],
				collection_method: 'charge_automatically'
			})
		]);

		const monthlyPaymentIntent = (monthlySubscription.latest_invoice as Stripe.Invoice)!
			.payment_intent as Stripe.PaymentIntent;
		const annualPaymentIntent = (annualSubscription.latest_invoice as Stripe.Invoice)!
			.payment_intent as Stripe.PaymentIntent;

		const proratedAmount = monthlyPaymentIntent.amount + annualPaymentIntent.amount;
		const proratedMonthlyAmount = monthlyPaymentIntent.amount;
		const proratedAnnualAmount = annualPaymentIntent.amount;

		cookies.set(
			'stripe-payment-info',
			JSON.stringify({
				customerId: waitlistedMemberData.customer_id!,
				annualSubscriptionPaymentIntendId: annualPaymentIntent.id,
				membershipSubscriptionPaymentIntendId: monthlyPaymentIntent.id
			} satisfies StripePaymentInfo),
			{ path: '/', httpOnly: true, secure: true, sameSite: 'strict' }
		);

		return {
			form: await superValidate({}, valibot(memberSignupSchema), { errors: false }),
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
				amount: proratedAmount,
				currency: 'EUR'
			}).toJSON(),
			proratedMonthlyPrice: Dinero({
				amount: proratedMonthlyAmount,
				currency: 'EUR'
			}).toJSON(),
			proratedAnnualPrice: Dinero({
				amount: proratedAnnualAmount,
				currency: 'EUR'
			}).toJSON(),
			monthlyFee: Dinero({
				amount: monthlySubscription.plan.amount,
				currency: 'EUR'
			}).toJSON(),
			annualFee: Dinero({
				amount: annualSubscription.plan.amount,
				currency: 'EUR'
			}).toJSON(),
			nextMonthlyBillingDate: dayjs().add(1, 'month').startOf('month').toDate(),
			nextAnnualBillingDate: dayjs().add(1, 'year').startOf('year').set('date', 7).toDate()
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
		const accessToken = event.cookies.get('access-token');
		invariant(accessToken === null, 'There has ben an error with your signup.');
		const tokenClaim = jwtDecode(accessToken!);
		const paymentInfo = event.cookies.get('stripe-payment-info');
		invariant(paymentInfo == undefined, 'Payment info not found.');
		invariant(dayjs.unix(tokenClaim.exp!).isBefore(dayjs()), 'This invitation has expired');

		const form = await superValidate(event, valibot(memberSignupSchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		const {
			customerId,
			annualSubscriptionPaymentIntendId,
			membershipSubscriptionPaymentIntendId
		}: StripePaymentInfo = JSON.parse(paymentInfo!);
		const confirmationToken: Stripe.ConfirmationToken = JSON.parse(
			form.data.stripeConfirmationToken
		);

		return kysely
			.transaction()
			.execute(async (trx) => {
				// First complete the member registration
				await completeMemberRegistration(
					{
						v_user_id: tokenClaim.sub!,
						p_next_of_kin_name: form.data.nextOfKin,
						p_next_of_kin_phone: form.data.nextOfKinNumber,
						p_insurance_form_submitted: form.data.insuranceFormSubmitted
					},
					trx
				);
				const intent = await stripeClient.setupIntents.create({
					confirm: true,
					customer: customerId,
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
						: (intent.payment_method! as Stripe.PaymentMethod)!.id;
				// const [monthlySubscription, annualSubscription] = await getMembershipSubcriptions({
				// 	customerId,
				// 	paymentMedhodId: paymentMethodId
				// });

				await Promise.all([
					stripeClient.paymentIntents.confirm(membershipSubscriptionPaymentIntendId, {
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
					stripeClient.paymentIntents.confirm(annualSubscriptionPaymentIntendId, {
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

				// Success! Delete the access token cookie
				event.cookies.delete('access-token', { path: '/' });
				return message(form, { paymentFailed: false });
			})
			.catch((err) => {
				console.error('Error in signup transaction:', err);
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
