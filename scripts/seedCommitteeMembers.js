import { createClient } from '@supabase/supabase-js';
import { parse } from 'csv-parse/sync';
import dotenv from 'dotenv';
import fs from 'fs';
import dayjs from 'dayjs';
import customParseFormat from 'dayjs/plugin/customParseFormat.js';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Load env file from project root
dotenv.config({ path: join(__dirname, '..', '.env') });

dayjs.extend(customParseFormat);

const supabaseUrl = process.env.PUBLIC_SUPABASE_URL;
const serviceRoleKey = process.env.SERVICE_ROLE_KEY;

if (!supabaseUrl || !serviceRoleKey) {
	throw new Error('Missing SUPABASE_URL or SERVICE_ROLE_KEY in environment variables');
}

const supabase = createClient(supabaseUrl, serviceRoleKey);

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
			is_active: true
		});

		if (profileError) {
			console.error(`Error creating profile for ${record.email}:`, profileError.message);
			console.log('Profile Error details:', profileError);
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
