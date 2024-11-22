import { createClient } from '@supabase/supabase-js';
import { faker } from '@faker-js/faker';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import dotenv from 'dotenv';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Load env file from project root
dotenv.config({ path: join(__dirname, '..', '.env') });

const supabaseUrl = process.env.PUBLIC_SUPABASE_URL;
const serviceRoleKey = process.env.SERVICE_ROLE_KEY;

if (!supabaseUrl || !serviceRoleKey) {
	throw new Error('Missing SUPABASE_URL or SERVICE_ROLE_KEY in environment variables');
}

const supabase = createClient(supabaseUrl, serviceRoleKey);

async function seedWaitlist(count = 10) {
	const entries = Array.from({ length: count }, () => ({
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email: faker.internet.email(),
		phone_number: faker.phone.number({ style: 'international' }),
		date_of_birth: faker.date.between({
			from: '1970-01-01',
			to: new Date(Date.now() - 16 * 365 * 24 * 60 * 60 * 1000)
		}),
		medical_conditions: faker.helpers.arrayElement([null, faker.lorem.sentence()]),
		insurance_form_submitted: faker.datatype.boolean(),
		status: 'waiting',
		admin_notes: faker.helpers.arrayElement([null, faker.lorem.paragraph()])
	}));

	const { data, error } = await supabase.from('waitlist').insert(entries).select();

	if (error) {
		console.error('Error seeding data:', error);
		return;
	}

	console.log(`Successfully inserted ${data.length} waitlist entries`);
}

const count = process.argv[2] ? parseInt(process.argv[2]) : 10;

seedWaitlist(count)
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(-1);
	});

export { seedWaitlist };
