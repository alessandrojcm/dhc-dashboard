import { faker } from '@faker-js/faker/locale/en_IE';
import { createClient } from '@supabase/supabase-js';
import 'dotenv/config';
import stripe from 'stripe';

import type { Database } from '../src/database.types';
import { ANNUAL_FEE_LOOKUP, MEMBERSHIP_FEE_LOOKUP_NAME } from '../src/lib/server/constants';
import { createSeedClient } from '@snaplet/seed';
import dayjs from 'dayjs';

export const stripeClient = new stripe(process.env.STRIPE_SECRET_KEY || '', {
	apiVersion: '2025-04-30.basil'
});

export function getSupabaseServiceClient() {
	const supabaseUrl = process.env.PUBLIC_SUPABASE_URL;
	const serviceRoleKey = process.env.SERVICE_ROLE_KEY;
	if (!supabaseUrl || !serviceRoleKey) {
		throw new Error('Missing SUPABASE_URL or SERVICE_ROLE_KEY in environment variables');
	}
	return createClient<Database>(supabaseUrl, serviceRoleKey);
}

const defaultValues = {
	addWaitlist: true,
	addSupabaseId: true,
	setWaitlistNotCompleted: false
};

export async function setupWaitlistedUser(
	params: Partial<{
		addWaitlist: boolean;
		addSupabaseId: boolean;
		setWaitlistNotCompleted: boolean;
		email: string;
	}> = {}
) {
	const overrides = {
		...defaultValues,
		...params,
		email: faker.internet.email().toLowerCase()
	};
	const { addSupabaseId, addWaitlist, setWaitlistNotCompleted, email } = overrides;
	const supabaseServiceClient = getSupabaseServiceClient();
	const testData = {
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email,
		date_of_birth: faker.date.birthdate({ min: 16, max: 65, mode: 'age' }),
		pronouns: faker.helpers.arrayElement(['he/him', 'she/her', 'they/them']),
		gender: faker.helpers.arrayElement([
			'man (cis)',
			'woman (cis)',
			'non-binary'
		] as Database['public']['Enums']['gender'][]),
		weapon: faker.helpers.arrayElement(['longsword', 'rapier', 'sabre']),
		phone_number: faker.phone.number({ style: 'international' }),
		next_of_kin: {
			name: faker.person.fullName(),
			phone_number: faker.phone.number({ style: 'international' })
		},
		medical_conditions: faker.helpers.arrayElement(['None', 'Asthma', 'Previous knee injury'])
	};
	const waitlisEntry = await supabaseServiceClient
		.rpc('insert_waitlist_entry', {
			first_name: testData.first_name,
			last_name: testData.last_name,
			email: testData.email,
			date_of_birth: testData.date_of_birth.toISOString(),
			phone_number: testData.phone_number,
			pronouns: testData.pronouns,
			gender: testData.gender as Database['public']['Enums']['gender'],
			medical_conditions: testData.medical_conditions
		})
		.single();
	if (waitlisEntry.error) {
		throw new Error(waitlisEntry.error.message);
	}
	const inviteLink = await supabaseServiceClient.auth.admin.createUser({
		email: testData.email,
		password: 'password',
		email_confirm: true
	});
	if (inviteLink.error) {
		throw new Error(inviteLink.error.message);
	}

	await supabaseServiceClient
		.from('user_profiles')
		.update({
			supabase_user_id: addSupabaseId ? inviteLink.data.user.id : null,
			waitlist_id: addWaitlist ? waitlisEntry.data.waitlist_id : null
		})
		.eq('id', waitlisEntry.data.profile_id)
		.select()
		.throwOnError();

	await supabaseServiceClient
		.from('waitlist')
		.update({
			status: setWaitlistNotCompleted ? 'cancelled' : 'completed'
		})
		.eq('email', testData.email)
		.throwOnError();
	const verifyOtp = await supabaseServiceClient.auth.signInWithPassword({
		email: testData.email,
		password: 'password'
	});
	if (verifyOtp.error) {
		throw new Error(verifyOtp.error.message);
	}
	await supabaseServiceClient.auth.signOut();

	function cleanUp() {
		// We need to create another client because when we use verifyOtp, we are effectively
		// logging as the user we are verifying the token for, hence we lose the service role privileges
		const client = getSupabaseServiceClient();
		return Promise.all([
			waitlisEntry?.data?.profile_id
				? client
						.from('user_profiles')
						.delete()
						.eq('id', waitlisEntry.data.profile_id)
						.throwOnError()
				: Promise.resolve(),
			inviteLink.data.user?.id
				? client.auth.admin.deleteUser(inviteLink.data.user.id)
				: Promise.resolve()
		]);
	}

	return Promise.resolve({
		...testData,
		waitlistId: waitlisEntry.data.waitlist_id,
		profileId: waitlisEntry.data.profile_id,
		token: verifyOtp.data.session?.access_token,
		cleanUp
	});
}

export async function createMember({
	email = faker.internet.email().toLowerCase(),
	roles = new Set(['member']),
	createSubscription = false
}: {
	email: string;
	roles?: Set<Database['public']['Enums']['role_type']>;
	createSubscription?: boolean;
}) {
	const supabaseServiceClient = getSupabaseServiceClient();
	const testData = {
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email: email,
		date_of_birth: faker.date.birthdate({ min: 16, max: 65, mode: 'age' }),
		pronouns: faker.helpers.arrayElement(['he/him', 'she/her', 'they/them']),
		gender: faker.helpers.arrayElement([
			'man (cis)',
			'woman (cis)',
			'non-binary'
		] as Database['public']['Enums']['gender'][]),
		weapon: faker.helpers.arrayElement(['longsword', 'rapier', 'sabre']),
		phone_number: faker.phone.number({ style: 'international' }),
		next_of_kin: {
			name: faker.person.fullName(),
			phone_number: faker.phone.number({ style: 'international' })
		},
		medical_conditions: faker.helpers.arrayElement(['None', 'Asthma', 'Previous knee injury'])
	};

	async function cleanUp() {
		// We need to create another client because when we use verifyOtp, we are effectively
		// logging as the user we are verifying the token for, hence we lose the service role privileges
		const client = getSupabaseServiceClient();
		if (waitlisEntry?.data?.profile_id) {
			await client
				.from('member_profiles')
				.delete()
				.eq('user_profile_id', waitlisEntry.data.profile_id)
				.throwOnError();
			await client
				.from('user_profiles')
				.delete()
				.eq('id', waitlisEntry.data.profile_id)
				.throwOnError();
		}
		if (inviteLink.data.user?.id) {
			await client.auth.admin.deleteUser(inviteLink.data.user.id);
		}
		if (cleanUpFn) {
			await cleanUpFn();
		}
		return Promise.resolve();
	}

	const waitlisEntry = await supabaseServiceClient
		.rpc('insert_waitlist_entry', {
			first_name: testData.first_name,
			last_name: testData.last_name,
			email: testData.email,
			date_of_birth: testData.date_of_birth.toISOString(),
			phone_number: testData.phone_number.toString(),
			pronouns: testData.pronouns,
			gender: testData.gender as Database['public']['Enums']['gender'],
			medical_conditions: testData.medical_conditions
		})
		.single();
	if (waitlisEntry.error) {
		throw new Error(waitlisEntry.error.message);
	}
	const inviteLink = await supabaseServiceClient.auth.admin.createUser({
		email: testData.email,
		password: 'password',
		email_confirm: true
	});
	if (inviteLink.error) {
		throw new Error(inviteLink.error.message);
	}
	let cleanUpFn: () => Promise<void>;
	let customerId: string | null = null;
	if (createSubscription) {
		const { cleanUp, ...rest } = await createStripeCustomerWithSubscription(testData.email);
		customerId = rest.customerId;
		cleanUpFn = cleanUp;
	}

	await supabaseServiceClient
		.from('user_profiles')
		.update({
			supabase_user_id: inviteLink.data.user.id,
			waitlist_id: waitlisEntry.data.waitlist_id,
			customer_id: customerId
		})
		.eq('id', waitlisEntry.data.profile_id)
		.select()
		.throwOnError();

	await supabaseServiceClient
		.from('user_roles')
		.insert(
			Array.from(roles)
				.filter((role) => role !== 'member')
				.map((role) => ({
					user_id: inviteLink.data.user.id,
					role
				}))
		)
		.throwOnError();

	await supabaseServiceClient
		.from('waitlist')
		.update({
			status: 'completed'
		})
		.eq('email', testData.email)
		.throwOnError();

	const { data } = await supabaseServiceClient
		.rpc('complete_member_registration', {
			v_user_id: inviteLink.data.user?.id || '',
			p_next_of_kin_name: testData.next_of_kin.name,
			p_next_of_kin_phone: testData.next_of_kin.phone_number,
			p_insurance_form_submitted: true
		})
		.throwOnError();
	const verifyOtp = await supabaseServiceClient.auth.signInWithPassword({
		email: testData.email,
		password: 'password'
	});
	if (verifyOtp.error) {
		throw new Error(verifyOtp.error.message);
	}
	await supabaseServiceClient.auth.signOut();
	return Promise.resolve({
		...testData,
		waitlistId: waitlisEntry.data.waitlist_id,
		profileId: waitlisEntry.data.profile_id,
		session: verifyOtp.data.session,
		memberId: data,
		userId: verifyOtp.data.user?.id,
		cleanUp
	});
}

export async function createStripeCustomerWithSubscription(email: string) {
	// Create a customer
	const customer = await stripeClient.customers.create({
		email,
		metadata: {
			source: 'test'
		}
	});

	// Create a SEPA Direct Debit payment method
	const paymentMethod = await stripeClient.paymentMethods.create({
		type: 'sepa_debit',
		sepa_debit: {
			iban: 'IE29AIBK93115212345678'
		},
		billing_details: {
			email,
			name: 'Test User'
		}
	});

	// Attach the payment method to the customer
	await stripeClient.paymentMethods.attach(paymentMethod.id, {
		customer: customer.id
	});

	// Set as default payment method
	await stripeClient.customers.update(customer.id, {
		invoice_settings: {
			default_payment_method: paymentMethod.id
		}
	});

	// Get the price ID for the membership fee
	let prices = await stripeClient.prices.search({
		query: `lookup_key:'${MEMBERSHIP_FEE_LOOKUP_NAME}'`
	});

	if (!prices.data.length) {
		throw new Error(`No price found with lookup key: ${MEMBERSHIP_FEE_LOOKUP_NAME}`);
	}

	// Create the subscription
	let subscription = await stripeClient.subscriptions.create({
		customer: customer.id,
		items: [{ price: prices.data[0].id }],
		default_payment_method: paymentMethod.id,
		expand: ['latest_invoice.payments']
	});

	// Get the price ID for the membership fee
	prices = await stripeClient.prices.search({
		query: `lookup_key:'${ANNUAL_FEE_LOOKUP}'`
	});

	if (!prices.data.length) {
		throw new Error(`No price found with lookup key: ${ANNUAL_FEE_LOOKUP}`);
	}

	// Create the subscription
	subscription = await stripeClient.subscriptions.create({
		customer: customer.id,
		items: [{ price: prices.data[0].id }],
		default_payment_method: paymentMethod.id,
		expand: ['latest_invoice.payments']
	});

	return {
		customerId: customer.id,
		subscriptionId: subscription.id,
		paymentMethodId: paymentMethod.id,
		async cleanUp() {
			await stripeClient.customers.del(customer.id);
		}
	};
}

export async function setupInvitedUser(
	params: Partial<{
		addInvitation: boolean;
		addSupabaseId: boolean;
		email: string;
		invitationStatus: Database['public']['Enums']['invitation_status'];
		token: string;
	}> = {}
) {
	const defaultInviteValues = {
		addInvitation: true,
		addSupabaseId: true,
		invitationStatus: 'pending' as Database['public']['Enums']['invitation_status']
	};
	const overrides = {
		...defaultInviteValues,
		...params,
		email: params.email || faker.internet.email().toLowerCase()
	};

	const { addSupabaseId, addInvitation, invitationStatus, email } = overrides;
	const supabaseServiceClient = getSupabaseServiceClient();

	// Create test user data
	const testData = {
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email,
		date_of_birth: faker.date.birthdate({ min: 16, max: 65, mode: 'age' }),
		pronouns: faker.helpers.arrayElement(['he/him', 'she/her', 'they/them']),
		gender: faker.helpers.arrayElement([
			'man (cis)',
			'woman (cis)',
			'non-binary'
		] as Database['public']['Enums']['gender'][]),
		weapon: faker.helpers.arrayElement(['longsword', 'rapier', 'sabre']),
		phone_number: faker.phone.number({ style: 'international' }),
		next_of_kin: {
			name: faker.person.fullName(),
			phone_number: faker.phone.number({ style: 'international' })
		},
		medical_conditions: faker.helpers.arrayElement(['None', 'Asthma', 'Previous knee injury'])
	};

	// Create a user in Supabase Auth
	const { data: authData, error: authError } = await supabaseServiceClient.auth.admin.createUser({
		email: testData.email,
		password: 'password',
		email_confirm: true,
		user_metadata: {
			first_name: testData.first_name,
			last_name: testData.last_name
		}
	});

	if (authError) {
		throw new Error(`Error creating user: ${authError.message}`);
	}

	// Create a Stripe customer for the invited user
	const customer = await stripeClient.customers.create({
		name: `${testData.first_name} ${testData.last_name}`,
		email: testData.email,
		metadata: {
			invited_by: 'e2e-test'
		}
	});

	// Calculate expiration date (24 hours from now)
	const expiresAt = new Date();
	expiresAt.setHours(expiresAt.getHours() + 24);

	// Create invitation using the stored procedure
	// This will also create the user profile
	const { error: invitationError, data: invitationData } = await supabaseServiceClient.rpc(
		'create_invitation',
		{
			v_user_id: authData.user.id,
			p_email: testData.email,
			p_first_name: testData.first_name,
			p_last_name: testData.last_name,
			p_date_of_birth: testData.date_of_birth.toISOString(),
			p_phone_number: testData.phone_number,
			p_invitation_type: 'admin',
			p_waitlist_id: undefined,
			p_expires_at: expiresAt.toISOString(),
			p_metadata: {}
		}
	);

	if (invitationError) {
		throw new Error(`Error creating invitation: ${invitationError.message}`);
	}

	// Update user profile with customer ID directly
	const { error: profileError } = await supabaseServiceClient
		.from('user_profiles')
		.update({ customer_id: customer.id })
		.eq('supabase_user_id', authData.user.id);

	if (profileError) {
		throw new Error(`Error updating user profile: ${profileError.message}`);
	}

	// User profile already has customer_id from the upsert operation above

	// Get price IDs for subscriptions
	const [monthlyPrices, annualPrices] = await Promise.all([
		stripeClient.prices.search({
			query: `lookup_key:'${MEMBERSHIP_FEE_LOOKUP_NAME}'`
		}),
		stripeClient.prices.search({
			query: `lookup_key:'${ANNUAL_FEE_LOOKUP}'`
		})
	]);

	if (!monthlyPrices.data.length || !annualPrices.data.length) {
		throw new Error('Failed to retrieve price IDs from Stripe');
	}

	// Create new subscriptions using Promise.all like in the Deno function
	const [monthlySubscription, annualSubscription] = await Promise.all([
		stripeClient.subscriptions.create({
			customer: customer.id,
			items: [{ price: monthlyPrices.data[0].id }],
			billing_cycle_anchor_config: {
				day_of_month: 1
			},
			payment_behavior: 'default_incomplete',
			payment_settings: {
				payment_method_types: ['sepa_debit']
			},
			expand: ['latest_invoice.payments'],
			collection_method: 'charge_automatically'
		}),
		stripeClient.subscriptions.create({
			customer: customer.id,
			items: [{ price: annualPrices.data[0].id }],
			payment_behavior: 'default_incomplete',
			payment_settings: {
				payment_method_types: ['sepa_debit']
			},
			billing_cycle_anchor_config: {
				month: 1,
				day_of_month: 7
			},
			expand: ['latest_invoice.payments'],
			collection_method: 'charge_automatically'
		})
	]);

	// Extract payment intents exactly as in the Deno function
	const monthlyInvoice = monthlySubscription.latest_invoice as String.Invoice;
	const annualInvoice = annualSubscription.latest_invoice as Stripe.Invoice;
	const monthlyPayment = monthlyInvoice.payments?.data?.[0]?.payment!;
	const annualPayment = annualInvoice.payments?.data?.[0]?.payment!;

	// Extract payment intent IDs
	const monthlyPaymentIntent = monthlyPayment.payment_intent! as string;
	const annualPaymentIntent = annualPayment.payment_intent! as string;

	// Create payment session directly in the database since create_payment_session stored procedure isn't available
	const { error: sessionError } = await supabaseServiceClient
		.from('payment_sessions')
		.insert({
			user_id: authData.user.id,
			monthly_subscription_id: monthlySubscription.id,
			annual_subscription_id: annualSubscription.id,
			monthly_payment_intent_id: monthlyPaymentIntent,
			annual_payment_intent_id: annualPaymentIntent,
			monthly_amount: monthlySubscription.items.data[0].plan.amount! as number,
			annual_amount: annualSubscription.items.data[0].plan.amount! as number,
			total_amount: monthlyInvoice.amount_due + annualInvoice.amount_due,
			expires_at: expiresAt.toISOString()
		})
		.select()
		.single();

	if (sessionError) {
		throw new Error(`Error creating payment session: ${sessionError.message}`);
	}

	// Cleanup function
	async function cleanUp() {
		const client = await createSeedClient();
		await client.$resetDatabase([
			'public.payment_sessions',
			'public.user_profiles',
			'public.invitations'
		]);
	}

	return Promise.resolve({
		...testData,
		date_of_birth: dayjs(testData.date_of_birth.toISOString()),
		invitationId: invitationData,
		token: async () => {
			// Sign in to get access token
			const verifyOtp = await supabaseServiceClient.auth.signInWithPassword({
				email: testData.email,
				password: 'password'
			});

			if (verifyOtp.error) {
				throw new Error(verifyOtp.error.message);
			}

			if (!verifyOtp.data.session || !verifyOtp.data.session.access_token) {
				throw new Error('Failed to get access token');
			}

			await supabaseServiceClient.auth.signOut();
			return verifyOtp.data.session.access_token;
		},
		cleanUp
	});
}
