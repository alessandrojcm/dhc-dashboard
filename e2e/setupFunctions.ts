import { faker } from '@faker-js/faker/locale/en_IE';
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import type { Database } from '../src/database.types';

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
	const inviteLink = await supabaseServiceClient.auth.admin.generateLink({
		type: 'invite',
		email: testData.email
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
	const verifyOtp = await supabaseServiceClient.auth.verifyOtp({
		token_hash: inviteLink.data.properties.hashed_token,
		type: 'invite'
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
	email = faker.internet.email().toLowerCase()
}: {
	email: string;
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
			client.auth.admin.deleteUser(inviteLink.data.user?.id)
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

	await supabaseServiceClient
		.from('user_profiles')
		.update({
			supabase_user_id: inviteLink.data.user.id,
			waitlist_id: waitlisEntry.data.waitlist_id
		})
		.eq('id', waitlisEntry.data.profile_id)
		.select()
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
			p_user_profile_id: waitlisEntry.data.profile_id,
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
		cleanUp
	});
}
