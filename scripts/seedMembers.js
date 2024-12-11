import { faker } from '@faker-js/faker';
import { supabase } from './supabaseServiceRole.js';

const PREFERRED_WEAPONS = ['longsword', 'sword_and_buckler'];
const GENDERS = ['man (cis)', 'woman (cis)', 'non-binary', 'man (trans)', 'woman (trans)', 'other'];
const PRONOUNS = ['he/him', 'she/her', 'they/them'];
const SOCIAL_MEDIA_CONSENT= ['no', 'yes_recognizable', 'yes_unrecognizable'];

async function createAuthUser(email, firstName, lastName) {
	const { data, error } = await supabase.auth.admin.createUser({
		email: email.toLowerCase(),
		email_confirm: true,
		password: 'password123',
		user_metadata: {
			full_name: `${firstName} ${lastName}`
		}
	});

	if (error) {
		console.error('Error creating auth user:', error);
		return null;
	}

	return data.user;
}

async function seedMembers(count = 10) {
	const members = Array.from({ length: count }, () => {
		const firstName = faker.person.firstName();
		const lastName = faker.person.lastName();
		return {
			first_name: firstName,
			last_name: lastName,
			email: faker.internet.email({ firstName, lastName }).toLowerCase(),
			phone_number: faker.phone.number('+353#########'),
			date_of_birth: faker.date.between({
				from: '1970-01-01',
				to: new Date(Date.now() - 16 * 365 * 24 * 60 * 60 * 1000)
			}),
			pronouns: faker.helpers.arrayElement(PRONOUNS),
			gender: faker.helpers.arrayElement(GENDERS),
			medical_conditions: faker.helpers.arrayElement([null, faker.lorem.sentence()])
		};
	});

	// Create auth users and user profiles
	const createdMembers = await Promise.all(
		members.map(async (member) => {
			// Create auth user
			const authUser = await createAuthUser(member.email, member.first_name, member.last_name);
			if (!authUser) return null;

			// Create waitlist entry first
			const { data: waitlist, error: waitlistError } = await supabase
				.from('waitlist')
				.insert({
					email: member.email,
					status: 'completed'
				})
				.select()
				.single();

			if (waitlistError) {
				console.error('Error creating waitlist entry:', waitlistError);
				return null;
			}

			// Create user profile
			const { data: profile, error: profileError } = await supabase
				.from('user_profiles')
				.insert({
					supabase_user_id: authUser.id,
					first_name: member.first_name,
					last_name: member.last_name,
					phone_number: member.phone_number,
					date_of_birth: member.date_of_birth,
					pronouns: member.pronouns,
					gender: member.gender,
					is_active: true,
					waitlist_id: waitlist.id,
					medical_conditions: member.medical_conditions,
                    social_media_consent: faker.helpers.arrayElement(SOCIAL_MEDIA_CONSENT),
				})
				.select()
				.single();

			if (profileError) {
				console.error('Error creating user profile:', profileError);
				return null;
			}

			return {
				authUser,
				profile
			};
		})
	);

	// Filter out any failed creations
	const validMembers = createdMembers.filter(Boolean);

	// Create member profiles
	const memberProfiles = validMembers.map(({ authUser, profile }) => ({
		id: authUser.id,
		user_profile_id: profile.id,
		next_of_kin_name: faker.person.fullName(),
		next_of_kin_phone: faker.phone.number({ format: 'international' }),
		preferred_weapon: faker.helpers.arrayElements(PREFERRED_WEAPONS, { min: 1, max: 2 }),
		membership_start_date: faker.date.past({ years: 2 }),
		last_payment_date: faker.date.recent({ days: 30 }),
		insurance_form_submitted: faker.datatype.boolean(),
		additional_data: {}
	}));

	if (memberProfiles.length === 0) {
		console.log('No member profiles to create');
		return;
	}

	const { error: insertError } = await supabase.from('member_profiles').insert(memberProfiles);

	if (insertError) {
		console.error('Error inserting member profiles:', insertError);
		return;
	}

	// Add member role to users
	const { error: roleError } = await supabase.from('user_roles').insert(
		memberProfiles.map((profile) => ({
			user_id: profile.id,
			role: 'member'
		}))
	);

	if (roleError) {
		console.error('Error adding member roles:', roleError);
		return;
	}

	console.log(`Successfully created ${memberProfiles.length} member profiles`);
}

// Run with default 10 members if no argument provided
const count = process.argv[2] ? parseInt(process.argv[2]) : 10;
seedMembers(count).catch(console.error);
