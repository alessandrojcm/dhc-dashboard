import { faker } from '@faker-js/faker';
import { supabase } from './supabaseServiceRole.js';
import dayjs from 'dayjs';

const SOCIAL_MEDIA_CONSENT = ['no', 'yes_recognizable', 'yes_unrecognizable'];
async function seedWaitlist(count = 10) {
	const entries = Array.from({ length: count }, () => ({
		first_name: faker.person.firstName(),
		last_name: faker.person.lastName(),
		email: faker.internet.email().toLowerCase(),
		date_of_birth: faker.date.between({
			from: '1970-01-01',
			to: new Date(Date.now() - 16 * 365 * 24 * 60 * 60 * 1000)
		}),
		phone_number: faker.phone.number({ style: 'international' }),
		pronouns: faker.helpers.arrayElement(['he/him', 'she/her', 'they/them']),
		gender: faker.helpers.arrayElement([
			'man (cis)',
			'woman (cis)',
			'non-binary',
			'man (trans)',
			'woman (trans)',
			'other'
		]),
		medical_conditions: faker.helpers.arrayElement([null, faker.lorem.sentence()]),
		social_media_consent: faker.helpers.arrayElement(SOCIAL_MEDIA_CONSENT)
	}));

	await Promise.all(
		entries.map(async (entry) => {
			const { error, data } = await supabase.rpc('insert_waitlist_entry', entry);
			if (error) {
				console.error('Error seeding data:', error);
				return Promise.reject(error);
			}
			if (
				!entry.date_of_birth ||
				!dayjs(entry.date_of_birth).isAfter(dayjs().subtract(18, 'years'))
			) {
				return Promise.resolve();
			}
			await supabase
				.from('waitlist_guardians')
				.insert({
					profile_id: data[0].profile_id,
					first_name: faker.person.firstName(),
					last_name: faker.person.lastName(),
					phone_number: faker.phone.number()
				})
				.throwOnError();
			return Promise.resolve();
		})
	);
	console.log(`Successfully inserted ${entries.length} waitlist entries`);
}

const count = process.argv[2] ? parseInt(process.argv[2]) : 10;

seedWaitlist(count)
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(-1);
	});

export { seedWaitlist };
