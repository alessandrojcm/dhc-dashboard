import { faker } from '@faker-js/faker/locale/en_IE';
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import type { Database } from '../src/database.types';
import { ANNUAL_FEE_LOOKUP, MEMBERSHIP_FEE_LOOKUP_NAME } from '../src/lib/server/constants';
import stripe from 'stripe';

export const stripeClient = new stripe(process.env.STRIPE_SECRET_KEY!, {
	apiVersion: '2024-12-18.acacia'
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
	const overrides = { ...defaultValues, ...params, email: faker.internet.email().toLowerCase() };
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
			client.from('user_profiles').delete().eq('id', waitlisEntry?.data?.profile_id).throwOnError(),
			client.auth.admin.deleteUser(inviteLink.data.user?.id)
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
		await client
			.from('member_profiles')
			.delete()
			.eq('user_profile_id', waitlisEntry?.data?.profile_id)
			.throwOnError();
		return Promise.all([
			client.from('user_profiles').delete().eq('id', waitlisEntry?.data?.profile_id).throwOnError(),
			client.auth.admin.deleteUser(inviteLink.data.user?.id),
			cleanUpFn?.()
		]);
	}
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

	const { data, error } = await supabaseServiceClient
		.rpc('complete_member_registration', {
			v_user_id: inviteLink.data.user.id,
			p_next_of_kin_name: testData.next_of_kin.name,
			p_next_of_kin_phone: testData.next_of_kin.phone_number,
			p_insurance_form_submitted: true
		})
		.throwOnError();
	if (error) {
		throw new Error(error.message);
	}
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
		expand: ['latest_invoice.payment_intent']
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
		expand: ['latest_invoice.payment_intent']
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
