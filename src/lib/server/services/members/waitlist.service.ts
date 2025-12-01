import * as v from 'valibot';
import { sql } from 'kysely';
import type { KyselyDatabase } from '$lib/types';
import type { Kysely, Session, Transaction, Logger } from '$lib/server/services/shared';
import { executeWithRLS, sentryLogger } from '$lib/server/services/shared';
import type { WaitlistEntry, InsertWaitlistEntryResult } from './waitlist-types';
import { dobValidator, phoneNumberValidator } from '$lib/schemas/commonValidators';
import { SocialMediaConsent } from '$lib/types';
import dayjs from 'dayjs';

// Calculate age helper
export const calculateAge = (dateOfBirth: Date) => dayjs().diff(dateOfBirth, 'years');
export const isMinor = (dateOfBirth: Date) => calculateAge(dateOfBirth) < 18;

// Guardian schema (optional fields)
const guardianDataSchema = v.partial(
	v.object({
		guardianFirstName: v.optional(
			v.pipe(v.string(), v.nonEmpty('Guardian first name is required.'))
		),
		guardianLastName: v.optional(v.pipe(v.string(), v.nonEmpty('Guardian last name is required.'))),
		guardianPhoneNumber: v.optional(phoneNumberValidator('Guardian phone number is required.'))
	})
);

// Main waitlist entry schema with conditional guardian validation
export const WaitlistEntrySchema = v.pipe(
	v.object({
		firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
		lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
		email: v.pipe(
			v.string(),
			v.nonEmpty('Please enter your email.'),
			v.email('Email is invalid.'),
			v.transform((input) => input.toLowerCase())
		),
		phoneNumber: phoneNumberValidator(),
		dateOfBirth: dobValidator,
		medicalConditions: v.pipe(v.string()),
		pronouns: v.pipe(
			v.string(),
			v.check(
				(input) => /^\/?[\w-]+(\/[\w-]+)*\/?$/.test(input),
				'Pronouns must be written between slashes (e.g., he/him/they).'
			)
		),
		gender: v.pipe(v.string(), v.nonEmpty('Please select your gender.')),
		socialMediaConsent: v.optional(
			v.enum(SocialMediaConsent, 'Please select an option'),
			SocialMediaConsent.no
		),
		...guardianDataSchema.entries
	}),
	v.forward(
		v.partialCheck(
			[['dateOfBirth'], ['guardianFirstName']],
			({ dateOfBirth, guardianFirstName }) => {
				if (!isMinor(dateOfBirth)) return true;
				return v.safeParse(v.required(guardianDataSchema, ['guardianFirstName']), {
					guardianFirstName
				}).success;
			},
			'Guardian first name is required for under 18s.'
		),
		['guardianFirstName']
	),
	v.forward(
		v.partialCheck(
			[['dateOfBirth'], ['guardianLastName']],
			({ dateOfBirth, guardianLastName }) => {
				if (!isMinor(dateOfBirth)) return true;
				return v.safeParse(v.required(guardianDataSchema, ['guardianLastName']), {
					guardianLastName
				}).success;
			},
			'Guardian last name is required for under 18s.'
		),
		['guardianLastName']
	),
	v.forward(
		v.partialCheck(
			[['dateOfBirth'], ['guardianPhoneNumber']],
			({ dateOfBirth, guardianPhoneNumber }) => {
				if (!isMinor(dateOfBirth)) return true;
				return v.safeParse(v.required(guardianDataSchema, ['guardianPhoneNumber']), {
					guardianPhoneNumber
				}).success;
			},
			'Guardian phone number is required for under 18s.'
		),
		['guardianPhoneNumber']
	),
	v.transform((input) => {
		if (!isMinor(input.dateOfBirth)) {
			delete input.guardianFirstName;
			delete input.guardianLastName;
			delete input.guardianPhoneNumber;
			return input;
		}
		return input;
	})
);

export type WaitlistEntryInput = v.InferOutput<typeof WaitlistEntrySchema>;

export class WaitlistService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		logger?: Logger
	) {
		this.logger = logger ?? sentryLogger;
	}

	/**
	 * Create a new waitlist entry with optional guardian information
	 * Uses the insert_waitlist_entry database function
	 */
	async create(input: WaitlistEntryInput): Promise<InsertWaitlistEntryResult> {
		this.logger.info('Creating waitlist entry', { email: input.email });

		return this.kysely.transaction().execute(async (trx) => {
			return this._create(trx, input);
		});
	}

	/**
	 * Private transactional method for creating waitlist entry
	 * Can be used by other services that need to coordinate across domains
	 */
	async _create(
		trx: Transaction<KyselyDatabase>,
		input: WaitlistEntryInput
	): Promise<InsertWaitlistEntryResult> {
		// Call database function to insert waitlist entry
		const result = await sql<InsertWaitlistEntryResult>`select *
			 from insert_waitlist_entry(
				 ${input.firstName},
				 ${input.lastName},
				 ${input.email},
				 ${input.dateOfBirth.toISOString()},
				 ${input.phoneNumber},
				 ${input.pronouns.toLowerCase()},
				 ${input.gender},
				 ${input.medicalConditions},
				 ${input.socialMediaConsent}
					)`
			.execute(trx)
			.then((r) => r.rows[0]);

		const profileId = result.profile_id;
		const age = calculateAge(input.dateOfBirth);

		// If minor and has guardian info, insert guardian record
		if (
			[input.guardianFirstName, input.guardianLastName, input.guardianPhoneNumber, age < 18].every(
				Boolean
			)
		) {
			await trx
				.insertInto('waitlist_guardians')
				.values({
					profile_id: profileId,
					first_name: input.guardianFirstName!,
					last_name: input.guardianLastName!,
					phone_number: input.guardianPhoneNumber!
				})
				.execute();
		}

		return result;
	}

	/**
	 * Find waitlist entries by status
	 */
	async findByStatus(status: WaitlistEntry['status'], session: Session): Promise<WaitlistEntry[]> {
		this.logger.info('Finding waitlist entries by status', { status });

		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			return trx.selectFrom('waitlist').selectAll().where('status', '=', status).execute();
		});
	}

	/**
	 * Find a single waitlist entry by ID
	 */
	async findById(id: string, session: Session): Promise<WaitlistEntry | undefined> {
		this.logger.info('Finding waitlist entry by ID', { id });

		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			return trx.selectFrom('waitlist').selectAll().where('id', '=', id).executeTakeFirst();
		});
	}

	/**
	 * Update waitlist entry status
	 */
	async updateStatus(
		id: string,
		status: WaitlistEntry['status'],
		session: Session
	): Promise<WaitlistEntry> {
		this.logger.info('Updating waitlist entry status', { id, status });

		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			return trx
				.updateTable('waitlist')
				.set({ status, last_status_change: new Date().toISOString() })
				.where('id', '=', id)
				.returningAll()
				.executeTakeFirstOrThrow();
		});
	}

	/**
	 * Get guardian information for a waitlist entry
	 */
	async getGuardian(profileId: string, session: Session) {
		this.logger.info('Getting guardian for profile', { profileId });

		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			return trx
				.selectFrom('waitlist_guardians')
				.selectAll()
				.where('profile_id', '=', profileId)
				.executeTakeFirst();
		});
	}
}
