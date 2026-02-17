import fs from 'node:fs';
import { parse } from 'csv-parse/sync';
import dayjs from 'dayjs';
import customParseFormat from 'dayjs/plugin/customParseFormat.js';
import { supabase } from './supabaseServiceRole.js';

dayjs.extend(customParseFormat);

async function seedUsers(csvPath) {
	const fileContent = fs.readFileSync(csvPath, 'utf-8');
	const records = parse(fileContent, {
		columns: true,
		skip_empty_lines: true,
		trim: true
	});

	for (const record of records) {
		const parsedDate = dayjs(record.dob, 'DD/MM/YYYY');
		const roles = record.roles.split(',').map((role) => role.trim());
		// Create auth user first
		const { data: authUser, error: authError } = await supabase.auth.admin.createUser({
			email: record.email,
			email_confirm: true,
			user_metadata: {
				display_name: record.displayname
			},
			app_metadata: {
				roles: roles
			}
		});

		if (authError) {
			console.error(`Error creating auth user for ${record.email}:`, authError.message);
			console.log('Auth Error details:', authError);
			continue;
		}

		// Create profile
		const { error: profileError } = await supabase.from('user_profiles').insert({
			id: authUser.user.id,
			first_name: record.first_name,
			last_name: record.last_name,
			date_of_birth: parsedDate.format('YYYY-MM-DD'),
			is_active: true,
			pronouns: record.pronouns,
			gender: record.gender,
			supabase_user_id: authUser.user.id
		});

		if (profileError) {
			console.error(`Error creating profile for ${record.email}:`, profileError.message);
			console.log('Profile Error details:', profileError);
			await supabase.auth.admin.deleteUser(authUser.user.id, false);
			continue;
		}

		// Create roles
		const roleEntries = roles.map((role) => ({
			user_id: authUser.user.id,
			role: role
		}));

		const { error: roleError } = await supabase.from('user_roles').insert(roleEntries);

		if (roleError) {
			console.error(`Error inserting roles for ${record.email}:`, roleError.message);
			console.log('Role Error details:', roleError);
			await supabase.auth.admin.deleteUser(authUser.user.id, false);
		}

		// create member_profiles entry
		const { error: memberError } = await supabase.from('member_profiles').insert({
			id: authUser.user.id,
			user_profile_id: authUser.user.id,
			next_of_kin_name: record.next_of_kin_name,
			next_of_kin_phone: record.next_of_kin_phone,
			preferred_weapon: record.preferred_weapon.split(',').map((weapon) => weapon.trim()),
			insurance_form_submitted: true,
			additional_data: record.additional_data
		});

		if (memberError) {
			console.error(`Error creating member profile for ${record.email}:`, memberError.message);
			console.log('Member Error details:', memberError);
			await supabase.auth.admin.deleteUser(authUser.user.id, false);
		}
	}

	console.log(`Finished processing ${records.length} users`);
}

const csvPath = process.argv[2];
if (!csvPath) {
	console.error('Please provide path to CSV file');
	process.exit(1);
}
seedUsers(csvPath)
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(-1);
	});

export { seedUsers };
