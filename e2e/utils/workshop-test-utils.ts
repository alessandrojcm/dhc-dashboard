import { faker } from '@faker-js/faker/locale/en_IE';
import { createClient } from '@supabase/supabase-js';
import dayjs from 'dayjs';
import type { Database } from '../../src/database.types';
import { getSupabaseServiceClient } from '../setupFunctions';

export type WorkshopTestData = {
	workshop_date: string;
	location: string;
	coach_id: string;
	capacity: number;
	notes_md?: string;
};

export type WorkshopStatus = 'draft' | 'published' | 'finished' | 'cancelled';

export const workshopTemplates = {
	basic: {
		workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
		location: 'Main Training Hall',
		capacity: 16,
		notes_md: 'Basic longsword techniques for beginners'
	},
	advanced: {
		workshop_date: dayjs().add(45, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
		location: 'Secondary Training Room',
		capacity: 12,
		notes_md: '## Advanced Topics\n- Complex binds\n- Advanced footwork'
	},
	weekend: {
		workshop_date: dayjs().add(14, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
		location: 'Outdoor Training Area',
		capacity: 20,
		notes_md: 'Weekend intensive workshop'
	},
	pastDate: {
		workshop_date: dayjs().subtract(1, 'day').format('YYYY-MM-DDTHH:mm:ss[Z]'),
		location: 'Test Location',
		capacity: 10,
		notes_md: 'Past date workshop (should fail)'
	},
	invalidCapacity: {
		workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
		location: 'Test Location',
		capacity: 0,
		notes_md: 'Invalid capacity workshop'
	}
};

export const testUsers = {
	admin: { roles: ['admin'], permissions: 'full' },
	president: { roles: ['president'], permissions: 'full' },
	beginners_coordinator: { roles: ['beginners_coordinator'], permissions: 'full' },
	coach: { roles: ['coach'], permissions: 'limited' },
	member: { roles: ['member'], permissions: 'read-only' },
	anonymous: { roles: [], permissions: 'none' }
};

export class WorkshopTestHelper {
	private supabase: ReturnType<typeof createClient<Database>>;
	private createdWorkshops: string[] = [];
	private createdUsers: string[] = [];

	constructor() {
		this.supabase = getSupabaseServiceClient();
	}

	async createTestCoach() {
		const coachData = {
			first_name: faker.person.firstName(),
			last_name: faker.person.lastName(),
			email: `coach-${Date.now()}-${Math.random().toString(36).substr(2, 9)}@test.com`,
			date_of_birth: faker.date.birthdate({ min: 25, max: 45, mode: 'age' }),
			pronouns: faker.helpers.arrayElement(['he/him', 'she/her', 'they/them']),
			gender: faker.helpers.arrayElement([
				'man (cis)',
				'woman (cis)',
				'non-binary'
			] as Database['public']['Enums']['gender'][]),
			phone_number: faker.phone.number({ style: 'international' }),
			medical_conditions: faker.helpers.arrayElement(['None', 'Asthma', 'Previous knee injury'])
		};

		// Create waitlist entry using the same RPC as existing code
		const waitlisEntry = await this.supabase
			.rpc('insert_waitlist_entry', {
				first_name: coachData.first_name,
				last_name: coachData.last_name,
				email: coachData.email,
				date_of_birth: coachData.date_of_birth.toISOString(),
				phone_number: coachData.phone_number,
				pronouns: coachData.pronouns,
				gender: coachData.gender as Database['public']['Enums']['gender'],
				medical_conditions: coachData.medical_conditions
			})
			.single();

		if (waitlisEntry.error) {
			throw new Error(`Error creating coach waitlist entry: ${waitlisEntry.error.message}`);
		}

		const { data: authUser, error: authError } = await this.supabase.auth.admin.createUser({
			email: coachData.email,
			password: 'password',
			email_confirm: true,
			user_metadata: {
				first_name: coachData.first_name,
				last_name: coachData.last_name
			}
		});

		if (authError) {
			throw new Error(`Error creating coach user: ${authError.message}`);
		}

		// Update the user profile with the supabase user ID
		await this.supabase
			.from('user_profiles')
			.update({
				supabase_user_id: authUser.user.id,
				waitlist_id: waitlisEntry.data.waitlist_id
			})
			.eq('id', waitlisEntry.data.profile_id)
			.throwOnError();

		// Complete member registration
		await this.supabase
			.rpc('complete_member_registration', {
				v_user_id: authUser.user.id,
				p_next_of_kin_name: faker.person.fullName(),
				p_next_of_kin_phone: faker.phone.number({ style: 'international' }),
				p_insurance_form_submitted: true
			})
			.throwOnError();

		// Add coach role
		const { error: roleError } = await this.supabase.from('user_roles').insert({
			user_id: authUser.user.id,
			role: 'coach'
		});

		if (roleError) {
			throw new Error(`Error assigning coach role: ${roleError.message}`);
		}

		this.createdUsers.push(authUser.user.id);

		return {
			id: waitlisEntry.data.profile_id,
			userId: authUser.user.id,
			...coachData
		};
	}

	async createTestWorkshop(
		template: keyof typeof workshopTemplates = 'basic',
		overrides: Partial<WorkshopTestData> = {}
	): Promise<Database['public']['Tables']['workshops']['Row']> {
		const coach = await this.createTestCoach();
		const workshopData = {
			...workshopTemplates[template],
			coach_id: coach.id,
			...overrides
		};

		const { data, error } = await this.supabase
			.from('workshops')
			.insert({
				...workshopData,
				status: 'draft',
				batch_size: 16,
				cool_off_days: 5,
				stripe_price_key: null
			})
			.select()
			.single();

		if (error) {
			throw new Error(`Error creating workshop: ${error.message}`);
		}

		this.createdWorkshops.push(data.id);
		return data;
	}

	async createTestWorkshopWithStatus(
		status: WorkshopStatus,
		template: keyof typeof workshopTemplates = 'basic',
		overrides: Partial<WorkshopTestData> = {}
	): Promise<Database['public']['Tables']['workshops']['Row']> {
		const workshop = await this.createTestWorkshop(template, overrides);

		if (status !== 'draft') {
			const { data, error } = await this.supabase
				.from('workshops')
				.update({ status })
				.eq('id', workshop.id)
				.select()
				.single();

			if (error) {
				throw new Error(`Error updating workshop status: ${error.message}`);
			}
			return data;
		}

		return workshop;
	}

	async addWorkshopAttendee(
		workshopId: string,
		attendeeProfileId: string,
		status: Database['public']['Enums']['workshop_attendee_status'] = 'invited'
	) {
		const { data, error } = await this.supabase
			.from('workshop_attendees')
			.insert({
				workshop_id: workshopId,
				user_profile_id: attendeeProfileId,
				status,
				invited_at: new Date().toISOString(),
				priority: 0
			})
			.select()
			.single();

		if (error) {
			throw new Error(`Error adding workshop attendee: ${error.message}`);
		}

		return data;
	}

	async getWorkshopById(id: string) {
		const { data, error } = await this.supabase.from('workshops').select('*').eq('id', id).single();

		if (error) {
			throw new Error(`Error fetching workshop: ${error.message}`);
		}

		return data;
	}

	async getWorkshopAttendees(workshopId: string) {
		const { data, error } = await this.supabase
			.from('workshop_attendees')
			.select('*')
			.eq('workshop_id', workshopId);

		if (error) {
			throw new Error(`Error fetching workshop attendees: ${error.message}`);
		}

		return data;
	}

	async updateWorkshopStatus(id: string, status: WorkshopStatus) {
		const { data, error } = await this.supabase
			.from('workshops')
			.update({ status })
			.eq('id', id)
			.select()
			.single();

		if (error) {
			throw new Error(`Error updating workshop status: ${error.message}`);
		}

		return data;
	}

	async deleteWorkshop(id: string) {
		const { error } = await this.supabase.from('workshops').delete().eq('id', id);

		if (error) {
			throw new Error(`Error deleting workshop: ${error.message}`);
		}
	}

	async cleanup() {
		// Clean up workshops first (due to foreign key constraints)
		if (this.createdWorkshops.length > 0) {
			await this.supabase.from('workshops').delete().in('id', this.createdWorkshops);
		}

		// Clean up users
		if (this.createdUsers.length > 0) {
			await Promise.all(
				this.createdUsers.map((userId) => this.supabase.auth.admin.deleteUser(userId))
			);
		}

		this.createdWorkshops = [];
		this.createdUsers = [];
	}
}

export function generateWorkshopApiPayload(
	template: keyof typeof workshopTemplates = 'basic',
	overrides: Partial<WorkshopTestData> = {}
): WorkshopTestData {
	return {
		...workshopTemplates[template],
		...overrides
	};
}

export function generateInvalidWorkshopPayloads() {
	return {
		missingDate: {
			location: 'Test Location',
			coach_id: 'test-coach-id',
			capacity: 16
		},
		missingLocation: {
			workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
			coach_id: 'test-coach-id',
			capacity: 16
		},
		missingCoach: {
			workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
			location: 'Test Location',
			capacity: 16
		},
		missingCapacity: {
			workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
			location: 'Test Location',
			coach_id: 'test-coach-id'
		},
		pastDate: {
			workshop_date: dayjs().subtract(1, 'day').format('YYYY-MM-DDTHH:mm:ss[Z]'),
			location: 'Test Location',
			coach_id: 'test-coach-id',
			capacity: 16
		},
		invalidDate: {
			workshop_date: 'invalid-date',
			location: 'Test Location',
			coach_id: 'test-coach-id',
			capacity: 16
		},
		zeroCapacity: {
			workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
			location: 'Test Location',
			coach_id: 'test-coach-id',
			capacity: 0
		},
		negativeCapacity: {
			workshop_date: dayjs().add(30, 'days').format('YYYY-MM-DDTHH:mm:ss[Z]'),
			location: 'Test Location',
			coach_id: 'test-coach-id',
			capacity: -1
		}
	};
}
