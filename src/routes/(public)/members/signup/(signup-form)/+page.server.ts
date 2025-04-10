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
import { STRIPE_SIGNUP_INFO } from '$lib/server/constants';
import { getPriceIds } from '$lib/server/priceManagement';
import Dinero from 'dinero.js';
import { kysely } from '$lib/server/kysely';
import Stripe from 'stripe';
import {
	completeMemberRegistration,
	getInvitationInfo,
	updateInvitationStatus
} from '$lib/server/kyselyRPCFunctions';
import type { PlanPricing } from '$lib/types';
import type { StripePaymentInfo } from '$lib/types';
import type { SubscriptionWithPlan } from '$lib/types';

// need to normalize medical_conditions
export const load: PageServerLoad = async ({ parent, cookies }) => {
	const { userData } = await parent();
	try {
		// Run these operations in parallel for better performance
		const [invitationData, existingSession, priceIds] = await Promise.all([
			kysely.transaction().execute(async (trx) => {
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
			}),
			kysely
				.selectFrom('payment_sessions')
				.select([
					'monthly_subscription_id',
					'annual_subscription_id',
					'monthly_payment_intent_id',
					'annual_payment_intent_id',
					'monthly_amount',
					'annual_amount',
					'coupon_id',
					'total_amount',
					'discounted_monthly_amount',
					'discounted_annual_amount',
					'discount_percentage'
				])
				.where('user_id', '=', userData.id)
				.where('expires_at', '>', dayjs().toISOString())
				.where('is_used', '=', false)
				.orderBy('created_at', 'desc')
				.executeTakeFirst(),
			getPriceIds() // Get cached price IDs
		]);

		let monthlyPaymentIntent: Stripe.PaymentIntent | undefined;
		let annualPaymentIntent: Stripe.PaymentIntent | undefined;
		let proratedMonthlyAmount: number = 0;
		let proratedAnnualAmount: number = 0;
		let monthlySubscription: Stripe.Subscription | undefined;
		let annualSubscription: Stripe.Subscription | undefined;
		let validExistingSession = false;

		if (existingSession) {
			// Retrieve the payment intents to ensure they're still valid
			try {
				const [retrievedMonthlyIntent, retrievedAnnualIntent] = await Promise.all([
					stripeClient.paymentIntents.retrieve(existingSession.monthly_payment_intent_id),
					stripeClient.paymentIntents.retrieve(existingSession.annual_payment_intent_id)
				]);

				// Only use if they're still in a usable state
				if (
					retrievedMonthlyIntent.status === 'requires_payment_method' &&
					retrievedAnnualIntent.status === 'requires_payment_method'
				) {
					monthlyPaymentIntent = retrievedMonthlyIntent;
					annualPaymentIntent = retrievedAnnualIntent;
					proratedMonthlyAmount = retrievedMonthlyIntent.amount;
					proratedAnnualAmount = retrievedAnnualIntent.amount;
					validExistingSession = true;

					// Retrieve subscriptions for display purposes
					const [retrievedMonthlySubscription, retrievedAnnualSubscription] = await Promise.all([
						stripeClient.subscriptions.retrieve(existingSession.monthly_subscription_id),
						stripeClient.subscriptions.retrieve(existingSession.annual_subscription_id)
					]);

					monthlySubscription = retrievedMonthlySubscription;
					annualSubscription = retrievedAnnualSubscription;
				} else {
					// Payment intents are in an unusable state, just mark as invalid
					console.log(
						'Payment intents are in an unusable state:',
						retrievedMonthlyIntent.status,
						retrievedAnnualIntent.status
					);
					validExistingSession = false;
				}
			} catch (error) {
				// If there's any error retrieving or validating, create new ones
				console.error('Error retrieving existing payment session:', error);
				validExistingSession = false;
			}
		}
		if (!existingSession || !validExistingSession) {
			// Create new subscriptions if no valid existing session
			const [newMonthlySubscription, newAnnualSubscription] = await Promise.all([
				stripeClient.subscriptions.create({
					customer: invitationData.customer_id!,
					items: [
						{
							price: priceIds.monthly // Use cached price ID
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
					customer: invitationData.customer_id!,
					items: [
						{
							price: priceIds.annual // Use cached price ID
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

			monthlySubscription = newMonthlySubscription;
			annualSubscription = newAnnualSubscription;

			const newMonthlyPaymentIntent = (newMonthlySubscription.latest_invoice as Stripe.Invoice)!
				.payment_intent as Stripe.PaymentIntent;
			const newAnnualPaymentIntent = (newAnnualSubscription.latest_invoice as Stripe.Invoice)!
				.payment_intent as Stripe.PaymentIntent;

			monthlyPaymentIntent = newMonthlyPaymentIntent;
			annualPaymentIntent = newAnnualPaymentIntent;
			proratedMonthlyAmount = newMonthlyPaymentIntent.amount;
			proratedAnnualAmount = newAnnualPaymentIntent.amount;

			// Store the new session
			await kysely
				.insertInto('payment_sessions')
				.values({
					user_id: userData.id,
					monthly_subscription_id: newMonthlySubscription.id,
					annual_subscription_id: newAnnualSubscription.id,
					monthly_payment_intent_id: newMonthlyPaymentIntent.id,
					annual_payment_intent_id: newAnnualPaymentIntent.id,
					// Save the full plan amounts (what user will pay regularly)
					monthly_amount: (monthlySubscription as unknown as SubscriptionWithPlan).plan.amount!,
					annual_amount: (annualSubscription as unknown as SubscriptionWithPlan).plan.amount!,
					// Save the prorated amount (what user will pay now)
					total_amount: proratedMonthlyAmount + proratedAnnualAmount,
					expires_at: dayjs().add(24, 'hour').toISOString()
				})
				.execute();
		}

		// Ensure payment intents are defined before using them
		if (!monthlyPaymentIntent || !annualPaymentIntent) {
			throw error(500, {
				message: 'Failed to create payment intents'
			});
		}

		cookies.set(
			STRIPE_SIGNUP_INFO,
			JSON.stringify({
				customerId: invitationData.customer_id!,
				annualSubscriptionPaymentIntendId: annualPaymentIntent.id,
				membershipSubscriptionPaymentIntendId: monthlyPaymentIntent.id
			} satisfies StripePaymentInfo),
			{ path: '/', httpOnly: true, secure: true, sameSite: 'strict' }
		);

		return {
			form: await superValidate({}, valibot(memberSignupSchema), { errors: false }),
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
			insuranceFormLink: supabaseServiceClient
				.from('settings')
				.select('value')
				.eq('key', 'insurance_form_link')
				.limit(1)
				.single()
				.then((result) => result.data?.value),
			planPricing: {
				proratedPrice: Dinero({
					// Use the total prorated amount that the user will pay now
					amount: proratedMonthlyAmount + proratedAnnualAmount,
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
					amount: (monthlySubscription as unknown as SubscriptionWithPlan).plan.amount!,
					currency: 'EUR'
				}).toJSON(),
				annualFee: Dinero({
					amount: (annualSubscription as unknown as SubscriptionWithPlan).plan.amount!,
					currency: 'EUR'
				}).toJSON(),
				// Include discounted amounts if they exist
				...(existingSession?.discounted_monthly_amount && {
					discountedMonthlyFee: Dinero({
						amount: existingSession.discounted_monthly_amount,
						currency: 'EUR'
					}).toJSON()
				}),
				...(existingSession?.discounted_annual_amount && {
					discountedAnnualFee: Dinero({
						amount: existingSession.discounted_annual_amount,
						currency: 'EUR'
					}).toJSON()
				}),
				// Use stored discount percentage if available, otherwise calculate it
				...(existingSession?.discount_percentage ? {
					discountPercentage: existingSession.discount_percentage
				} : existingSession?.discounted_monthly_amount ? {
					discountPercentage: Math.round(
						((monthlySubscription as unknown as SubscriptionWithPlan).plan.amount! - existingSession.discounted_monthly_amount) /
							(monthlySubscription as unknown as SubscriptionWithPlan).plan.amount! *
							100
					)
				} : {}),
				coupon: existingSession?.coupon_id ?? undefined
			} satisfies PlanPricing,
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
		invariant(accessToken === null, 'There has been an error with your signup.');
		const tokenClaim = jwtDecode(accessToken!);
		const paymentInfo = event.cookies.get(STRIPE_SIGNUP_INFO);
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
						: (intent.payment_method! as Stripe.PaymentMethod).id;

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

				// After successful payment confirmation, mark the session as used
				await trx
					.updateTable('payment_sessions')
					.set({ is_used: true })
					.where('monthly_payment_intent_id', '=', membershipSubscriptionPaymentIntendId)
					.where('annual_payment_intent_id', '=', annualSubscriptionPaymentIntendId)
					.execute();

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

				return message(form, { paymentFailed: true, error: errorMessage }, { status: 400 });
			});
	}
};
