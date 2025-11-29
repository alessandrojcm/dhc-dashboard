import { faker } from "@faker-js/faker";
import dayjs from "dayjs";
import { stripeClient } from "./stripeClient.js";
import { supabase } from "./supabaseServiceRole.js";

const PREFERRED_WEAPONS = ["longsword", "sword_and_buckler"];
const GENDERS = [
	"man (cis)",
	"woman (cis)",
	"non-binary",
	"man (trans)",
	"woman (trans)",
	"other",
];
const PRONOUNS = ["he/him", "she/her", "they/them"];
const SOCIAL_MEDIA_CONSENT = ["no", "yes_recognizable", "yes_unrecognizable"];

async function createAuthUser(email, firstName, lastName) {
	const { data, error } = await supabase.auth.admin.createUser({
		email: email.toLowerCase(),
		email_confirm: true,
		password: "password123",
		user_metadata: {
			full_name: `${firstName} ${lastName}`,
		},
	});

	if (error) {
		console.error("Error creating auth user:", error);
		return null;
	}

	return data.user;
}

async function seedMembers(count = 10) {
	// Generate member data
	const members = Array.from({ length: count }, () => {
		const firstName = faker.person.firstName();
		const lastName = faker.person.lastName();
		return {
			first_name: firstName,
			last_name: lastName,
			email: faker.internet.email({ firstName, lastName }).toLowerCase(),
			phone_number: faker.phone.number("+353#########"),
			date_of_birth: faker.date.between({
				from: "1970-01-01",
				to: new Date(Date.now() - 16 * 365 * 24 * 60 * 60 * 1000),
			}),
			pronouns: faker.helpers.arrayElement(PRONOUNS),
			gender: faker.helpers.arrayElement(GENDERS),
			medical_conditions: faker.helpers.arrayElement([
				null,
				faker.lorem.sentence(),
			]),
		};
	});

	// Create auth users in batch
	const authUsers = await Promise.all(
		members.map((member) =>
			createAuthUser(member.email, member.first_name, member.last_name),
		),
	);
	const validAuthUsers = authUsers.filter(Boolean);

	if (validAuthUsers.length === 0) {
		console.log("No auth users created");
		return;
	}

	// Prepare waitlist entries
	const waitlistEntries = validAuthUsers.map((_, index) => ({
		email: members[index].email,
		status: "completed",
	}));

	// Batch insert waitlist entries
	const { data: createdWaitlistEntries, error: waitlistError } = await supabase
		.from("waitlist")
		.insert(waitlistEntries)
		.select();

	if (waitlistError) {
		console.error("Error creating waitlist entries:", waitlistError);
		return;
	}

	// Prepare user profiles
	const userProfiles = validAuthUsers.map((authUser, index) => ({
		supabase_user_id: authUser.id,
		first_name: members[index].first_name,
		last_name: members[index].last_name,
		phone_number: members[index].phone_number,
		date_of_birth: members[index].date_of_birth,
		pronouns: members[index].pronouns,
		gender: members[index].gender,
		is_active: true,
		waitlist_id: createdWaitlistEntries[index].id,
		medical_conditions: members[index].medical_conditions,
		social_media_consent: faker.helpers.arrayElement(SOCIAL_MEDIA_CONSENT),
	}));

	// Batch insert user profiles
	const { data: createdProfiles, error: profileError } = await supabase
		.from("user_profiles")
		.insert(userProfiles)
		.select();

	if (profileError) {
		console.error("Error creating user profiles:", profileError);
		return;
	}

	// Prepare member profiles
	const memberProfiles = validAuthUsers.map((authUser, index) => ({
		id: authUser.id,
		user_profile_id: createdProfiles[index].id,
		next_of_kin_name: faker.person.fullName(),
		next_of_kin_phone: faker.phone.number({ format: "international" }),
		preferred_weapon: faker.helpers.arrayElements(PREFERRED_WEAPONS, {
			min: 1,
			max: 2,
		}),
		membership_start_date: faker.date.past({ years: 2 }),
		last_payment_date: faker.date.recent({ days: 30 }),
		insurance_form_submitted: faker.datatype.boolean(),
		additional_data: {},
	}));

	// Batch insert member profiles
	const { error: memberProfileError, data: memberProfileData } = await supabase
		.from("member_profiles")
		.insert(memberProfiles);

	if (memberProfileError) {
		console.error("Error creating member profiles:", memberProfileError);
		return;
	}

	// Prepare user roles
	const userRoles = validAuthUsers.map((authUser) => ({
		user_id: authUser.id,
		role: "member",
	}));

	// Batch insert user roles
	const { error: roleError } = await supabase
		.from("user_roles")
		.insert(userRoles);

	if (roleError) {
		console.error("Error adding member roles:", roleError);
		return;
	}
	// Just the first 25 to avoid Stripe Rate Limiting
	const sliceMembers = userProfiles.slice(0, 25);
	await Promise.all(
		sliceMembers.map(async (member) => {
			const { id } = await stripeClient.customers.create({
				name: `${member.first_name} ${member.last_name}`,
				email: member.email,
			});
			await supabase
				.from("user_profiles")
				.update({
					customer_id: id,
				})
				.eq("supabase_user_id", member.supabase_user_id);
		}),
	);
	const underageMembers = createdProfiles.filter(
		(m) =>
			m.date_of_birth &&
			dayjs(m.date_of_birth).isAfter(dayjs().subtract(18, "years")),
	);
	await supabase
		.from("waitlist_guardians")
		.insert(
			underageMembers.map((m) => ({
				profile_id: m.id,
				first_name: faker.person.firstName(),
				last_name: faker.person.lastName(),
				phone_number: faker.phone.number(),
			})),
		)
		.throwOnError();

	console.log(`Successfully created ${memberProfiles.length} member profiles`);
}

// Run with default 10 members if no argument provided
const count = process.argv[2] ? parseInt(process.argv[2], 10) : 10;
seedMembers(count).catch(console.error);
