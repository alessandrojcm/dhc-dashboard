/**
 * Member Service
 * Handles member profile CRUD operations and queries
 */

import * as v from 'valibot';
import type { Database } from '$database';
import type { Kysely, Transaction, KyselyDatabase, Session, Logger } from '../shared';
import { executeWithRLS, sql } from '../shared';

// ============================================================================
// Types (derived from database.types.ts to prevent drift)
// ============================================================================

/**
 * Member data type from database composite type
 */
export type MemberData = Database['public']['CompositeTypes']['member_data_type'];

/**
 * Member with subscription info from member_management_view
 * Derived from database view type to prevent drift
 */
export type MemberWithSubscription = Database['public']['Views']['member_management_view']['Row'];

// ============================================================================
// Validation Schemas (exported for reuse in forms/APIs)
// ============================================================================

/**
 * Schema for updating member profile data
 * Export this for use in SuperForms
 */
export const MemberUpdateSchema = v.object({
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	phoneNumber: v.optional(v.string()),
	dateOfBirth: v.pipe(v.date(), v.maxValue(new Date(), 'Date of birth must be in the past.')),
	pronouns: v.optional(v.string()),
	gender: v.optional(
		v.picklist(
			['male', 'female', 'non_binary', 'other', 'prefer_not_to_say'],
			'Please select a valid gender.'
		)
	),
	medicalConditions: v.optional(v.string()),
	nextOfKin: v.optional(v.string()),
	nextOfKinNumber: v.optional(v.string()),
	preferredWeapon: v.optional(v.array(v.string())),
	insuranceFormSubmitted: v.optional(v.boolean()),
	socialMediaConsent: v.optional(
		v.picklist(['yes', 'no', 'ask_me'], 'Please select a valid option.')
	)
});

export type MemberUpdateInput = v.InferOutput<typeof MemberUpdateSchema>;

/**
 * Member profile update arguments
 * Used for updating both user_profiles and member_profiles tables
 */
export interface UpdateMemberDataArgs {
	user_uuid: string;
	p_first_name?: string | null;
	p_last_name?: string | null;
	p_is_active?: boolean | null;
	p_medical_conditions?: string | null;
	p_phone_number?: string | null;
	p_gender?: Database['public']['Enums']['gender'] | null;
	p_pronouns?: string | null;
	p_date_of_birth?: string | null;
	p_next_of_kin_name?: string | null;
	p_next_of_kin_phone?: string | null;
	p_preferred_weapon?: Database['public']['Enums']['preferred_weapon'][] | null;
	p_membership_start_date?: string | null;
	p_membership_end_date?: string | null;
	p_last_payment_date?: string | null;
	p_insurance_form_submitted?: boolean | null;
	p_additional_data?: Record<string, unknown> | null;
	p_social_media_consent?: Database['public']['Enums']['social_media_consent'] | null;
}

// ============================================================================
// Member Service
// ============================================================================

export class MemberService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger
	) {
		this.logger = logger ?? console;
	}

	// ========================================================================
	// Query Methods
	// ========================================================================

	/**
	 * Get member data by user ID using get_member_data RPC function
	 */
	async findById(userId: string): Promise<MemberData> {
		this.logger.info('Fetching member data', { userId });

		const result = await sql<MemberData>`
			select * from get_member_data(${userId}::uuid)
		`
			.execute(this.kysely)
			.then((r) => r.rows[0]);

		if (!result) {
			throw new Error('Member not found', {
				cause: { userId, context: 'MemberService.findById' }
			});
		}

		return result;
	}

	/**
	 * Get member with subscription info from member_management_view
	 */
	async findByIdWithSubscription(userId: string): Promise<MemberWithSubscription> {
		this.logger.info('Fetching member with subscription info', { userId });

		return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
			return this._findByIdWithSubscription(trx, userId);
		});
	}

	/**
	 * Get membership info (wrapper around get_membership_info RPC)
	 */
	async getMembershipInfo(userId: string): Promise<MemberData> {
		this.logger.info('Fetching membership info', { userId });

		const result = await sql<{
			get_membership_info: MemberData;
		}>`
			select * from get_membership_info(${userId}::uuid)
		`
			.execute(this.kysely)
			.then((r) => r.rows[0].get_membership_info);

		if (!result) {
			throw new Error('Membership info not found', {
				cause: { userId, context: 'MemberService.getMembershipInfo' }
			});
		}

		return result;
	}

	// ========================================================================
	// Mutation Methods
	// ========================================================================

	/**
	 * Update member profile data
	 * Public method that creates its own transaction
	 */
	async update(userId: string, input: MemberUpdateInput): Promise<MemberData> {
		this.logger.info('Updating member profile', { userId });

		return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
			return this._update(trx, userId, input);
		});
	}

	/**
	 * Update member using database function with full args
	 * Useful when you need to update fields not in MemberUpdateInput
	 */
	async updateWithArgs(args: UpdateMemberDataArgs): Promise<MemberData> {
		this.logger.info('Updating member with full args', {
			userId: args.user_uuid
		});

		return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
			return this._updateWithArgs(trx, args);
		});
	}

	// ========================================================================
	// Private Transactional Methods (for cross-service coordination)
	// ========================================================================

	/**
	 * Internal transactional method for updating member profile
	 */
	async _update(
		trx: Transaction<KyselyDatabase>,
		userId: string,
		input: MemberUpdateInput
	): Promise<MemberData> {
		// Map MemberUpdateInput to database function args
		const args: UpdateMemberDataArgs = {
			user_uuid: userId,
			p_first_name: input.firstName,
			p_last_name: input.lastName,
			p_phone_number: input.phoneNumber,
			p_date_of_birth: input.dateOfBirth?.toISOString(),
			p_pronouns: input.pronouns,
			p_gender: input.gender as Database['public']['Enums']['gender'],
			p_medical_conditions: input.medicalConditions,
			p_next_of_kin_name: input.nextOfKin,
			p_next_of_kin_phone: input.nextOfKinNumber,
			p_preferred_weapon:
				input.preferredWeapon as Database['public']['Enums']['preferred_weapon'][],
			p_insurance_form_submitted: input.insuranceFormSubmitted,
			p_social_media_consent:
				input.socialMediaConsent as Database['public']['Enums']['social_media_consent']
		};

		return this._updateWithArgs(trx, args);
	}

	/**
	 * Internal transactional method for updating member with full args
	 * Replaces the update_member_data stored procedure with pure Kysely
	 */
	async _updateWithArgs(
		trx: Transaction<KyselyDatabase>,
		args: UpdateMemberDataArgs
	): Promise<MemberData> {
		const userProfile = await trx
			.selectFrom('user_profiles')
			.select('id')
			.where('supabase_user_id', '=', args.user_uuid)
			.executeTakeFirst();

		if (!userProfile) {
			throw new Error(`User with UUID ${args.user_uuid} not found`, {
				cause: { userId: args.user_uuid, context: 'MemberService._updateWithArgs' }
			});
		}

		// Update user_profiles
		await trx
			.updateTable('user_profiles')
			.set((eb) => ({
				updated_at: eb.val(new Date().toISOString()),
				...(args.p_first_name != null && { first_name: eb.val(args.p_first_name) }),
				...(args.p_last_name != null && { last_name: eb.val(args.p_last_name) }),
				...(args.p_is_active != null && { is_active: eb.val(args.p_is_active) }),
				...(args.p_medical_conditions != null && { medical_conditions: eb.val(args.p_medical_conditions) }),
				...(args.p_phone_number != null && { phone_number: eb.val(args.p_phone_number) }),
				...(args.p_gender != null && { gender: eb.val(args.p_gender) }),
				...(args.p_pronouns != null && { pronouns: eb.val(args.p_pronouns) }),
				...(args.p_date_of_birth != null && { date_of_birth: eb.val(args.p_date_of_birth) }),
				...(args.p_social_media_consent != null && { social_media_consent: eb.val(args.p_social_media_consent) })
			}))
			.where('id', '=', userProfile.id)
			.execute();

		// Update member_profiles - use raw SQL for preferred_weapon enum array
		if (args.p_preferred_weapon != null && args.p_preferred_weapon.length > 0) {
			const weaponArray = `{${args.p_preferred_weapon.join(',')}}`;
			await sql`
				UPDATE member_profiles 
				SET preferred_weapon = ${weaponArray}::preferred_weapon[],
				    updated_at = NOW()
				WHERE user_profile_id = ${userProfile.id}
			`.execute(trx);
		}

		// Update other member_profiles fields
		const memberUpdate = {
			updated_at: new Date().toISOString(),
			...(args.p_next_of_kin_name != null && { next_of_kin_name: args.p_next_of_kin_name }),
			...(args.p_next_of_kin_phone != null && { next_of_kin_phone: args.p_next_of_kin_phone }),
			...(args.p_membership_start_date != null && { membership_start_date: args.p_membership_start_date }),
			...(args.p_membership_end_date != null && { membership_end_date: args.p_membership_end_date }),
			...(args.p_last_payment_date != null && { last_payment_date: args.p_last_payment_date }),
			...(args.p_insurance_form_submitted != null && { insurance_form_submitted: args.p_insurance_form_submitted }),
			...(args.p_additional_data != null && { additional_data: JSON.stringify(args.p_additional_data) })
		};

		await trx
			.updateTable('member_profiles')
			.set(memberUpdate)
			.where('user_profile_id', '=', userProfile.id)
			.execute();

		// Return the updated data
		const result = await sql<MemberData>`
			select * from get_member_data(${args.user_uuid}::uuid)
		`
			.execute(trx)
			.then((r) => r.rows[0]);

		if (!result) {
			throw new Error('Failed to fetch updated member data', {
				cause: { userId: args.user_uuid, context: 'MemberService._updateWithArgs' }
			});
		}

		return result;
	}

	/**
	 * Internal transactional method for fetching member with subscription
	 */
	async _findByIdWithSubscription(
		trx: Transaction<KyselyDatabase>,
		userId: string
	): Promise<MemberWithSubscription> {
		const member = await trx
			.selectFrom('member_management_view')
			.selectAll()
			.where('id', '=', userId)
			.executeTakeFirst();

		if (!member) {
			throw new Error('Member not found in management view', {
				cause: { userId, context: 'MemberService._findByIdWithSubscription' }
			});
		}

		return member as MemberWithSubscription;
	}

	/**
	 * Get current user profile data for comparison
	 * Useful for checking what changed before updating external systems
	 */
	async _getCurrentProfile(
		trx: Transaction<KyselyDatabase>,
		userId: string
	): Promise<{
		first_name: string | null;
		last_name: string | null;
		phone_number: string | null;
		customer_id: string | null;
	}> {
		const profile = await trx
			.selectFrom('user_profiles')
			.select(['first_name', 'last_name', 'phone_number', 'customer_id'])
			.where('supabase_user_id', '=', userId)
			.executeTakeFirst();

		if (!profile) {
			throw new Error('User profile not found', {
				cause: { userId, context: 'MemberService._getCurrentProfile' }
			});
		}

		return profile;
	}
}
