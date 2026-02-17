import * as Sentry from '@sentry/sveltekit';
import { error } from '@sveltejs/kit';
import type Stripe from 'stripe';
import { fail, message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { env } from '$env/dynamic/public';
import { memberSignupSchema } from '$lib/schemas/membersSignup';
import { invariant } from '$lib/server/invariant';
import { getKyselyClient } from '$lib/server/kysely';
import { getNextBillingDates, getPriceIds } from '$lib/server/pricingUtils';
import { createInvitationService } from '$lib/server/services/invitations';
import { stripeClient } from '$lib/server/stripe';
import type { Actions, PageServerLoad } from './$types';

const DASHBOARD_MIGRATION_CODE = env.PUBLIC_DASHBOARD_MIGRATION_CODE ?? 'DHCDASHBOARD';
// TODO: all of this broken now
// need to normalize medical_conditions
export const load: PageServerLoad = async ({ params, platform, cookies }) => {
	const invitationId = params.invitationId;
	const isConfirmed = Boolean(cookies.get(`invite-confirmed-${invitationId}`));

	try {
		// Create invitation service without session (public route)
		const invitationService = createInvitationService(platform!);

		// Get invitation data first (essential for page rendering)
		const invitationData = await invitationService.getInvitationInfo(invitationId);

		if (!invitationData) {
			return error(404, 'Invitation not found');
		}

		// Return essential data immediately, with pricing as a streamed promise
		return {
			form: await superValidate({}, valibot(memberSignupSchema), {
				errors: false
			}),
			userData: {
				firstName: invitationData.first_name,
				lastName: invitationData.last_name,
				email: invitationData.email,
				dateOfBirth: new Date(invitationData.date_of_birth),
				phoneNumber: invitationData.phone_number,
				pronouns: invitationData.pronouns,
				gender: invitationData.gender,
				medicalConditions: invitationData.medical_conditions
			},
			isConfirmed,
			insuranceFormLink: '',
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

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(memberSignupSchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		const kysely = getKyselyClient(event.platform?.env.HYPERDRIVE);
		const confirmationToken: Stripe.ConfirmationToken = JSON.parse(
			form.data.stripeConfirmationToken
		);

		// Create invitation service without session (public route)
		const invitationService = createInvitationService(event.platform!);

		return kysely
			.transaction()
			.execute(async (trx) => {
				// Process invitation acceptance (handles status update, registration, waitlist)
				const invitationData = await invitationService.processInvitationAcceptance(
					trx,
					event.params.invitationId,
					form.data.nextOfKin,
					form.data.nextOfKinNumber
				);

				// Get customer ID
				const customerId = await trx
					.selectFrom('user_profiles')
					.select('customer_id')
					.where('supabase_user_id', '=', invitationData.user_id)
					.executeTakeFirst();
				if (!customerId) {
					throw error(404, 'No customer ID found for this user.');
				}

				const intent = await stripeClient.setupIntents.create({
					confirm: true,
					customer: customerId.customer_id!,
					confirmation_token: confirmationToken.id,
					payment_method_types: ['sepa_debit']
				});

				invariant(
					intent.status === 'requires_payment_method',
					'payment_intent_requires_payment_method'
				);
				invariant(intent.payment_method == null, 'payment_method_not_found');
				const paymentMethodId =
					typeof intent.payment_method === 'string'
						? intent.payment_method
						: (intent.payment_method! as Stripe.PaymentMethod).id;

				// Fetch base Stripe prices
				const { monthly, annual } = await getPriceIds(kysely);

				if (!monthly || !annual) {
					Sentry.captureMessage('Base prices not found for membership products', {
						extra: { userId: invitationData.user_id }
					});
					throw error(500, 'Could not retrieve base product prices.');
				}
				let isMigration = false;
				let promotionCodeId: string | undefined;
				if (form.data.couponCode) {
					const promotionCodes = await stripeClient.promotionCodes.list({
						active: true,
						code: form.data.couponCode,
						limit: 1
					});
					if (!promotionCodes.data.length) {
						throw error(400, 'Invalid or inactive promotion code');
					}
					if (
						form.data.couponCode.toLowerCase().trim() ===
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
								day_of_month: 1
							},
							payment_behavior: 'default_incomplete',
							payment_settings: {
								payment_method_types: ['sepa_debit']
							},
							expand: ['latest_invoice.payments'],
							collection_method: 'charge_automatically',
							default_payment_method: paymentMethodId,
							discounts:
								!isMigration && promotionCodeId ? [{ promotion_code: promotionCodeId }] : undefined
						})
						.then(async (subscription) => {
							if ((subscription.latest_invoice as Stripe.Invoice).payments?.data.length === 0) {
								return;
							}
							if (isMigration) {
								return stripeClient.creditNotes.create({
									invoice: (subscription.latest_invoice as Stripe.Invoice).id!,
									amount: (subscription.latest_invoice as Stripe.Invoice).amount_due
								});
							}
							return stripeClient.paymentIntents.confirm(
								(subscription.latest_invoice as Stripe.Invoice).payments?.data[0].payment
									.payment_intent as string,
								{
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
								}
							);
						}),
					stripeClient.subscriptions
						.create({
							customer: customerId.customer_id!,
							items: [{ price: annual }],
							payment_behavior: 'default_incomplete',
							payment_settings: {
								payment_method_types: ['sepa_debit']
							},
							billing_cycle_anchor_config: {
								month: 1,
								day_of_month: 7
							},
							expand: ['latest_invoice.payments'],
							collection_method: 'charge_automatically',
							default_payment_method: paymentMethodId,
							discounts:
								!isMigration && promotionCodeId ? [{ promotion_code: promotionCodeId }] : undefined
						})
						.then(async (subscription) => {
							if ((subscription.latest_invoice as Stripe.Invoice).payments?.data.length === 0) {
								return;
							}
							if (isMigration) {
								return stripeClient.creditNotes.create({
									invoice: (subscription.latest_invoice as Stripe.Invoice).id!,
									amount: (subscription.latest_invoice as Stripe.Invoice).amount_due
								});
							}
							return stripeClient.paymentIntents.confirm(
								(subscription.latest_invoice as Stripe.Invoice).payments?.data[0].payment
									.payment_intent as string,
								{
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
								}
							);
						})
				]);

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
