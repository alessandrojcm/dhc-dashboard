/**
 * Invitation Service
 * Handles invitation CRUD operations and validation
 */

import * as v from 'valibot';
import type { Kysely, KyselyDatabase, Logger, Session, Transaction } from '../shared';
import { executeWithRLS, sql } from '../shared';
import type {
	CreateInvitationArgs,
	Invitation,
	InvitationInfo,
	InvitationStatus,
	InvitationType
} from './types';
import dayjs from 'dayjs';

// ============================================================================
// Validation Schemas (exported for reuse in forms/APIs)
// ============================================================================

/**
 * Schema for creating an invitation
 * Export this for use in SuperForms
 */
export const InvitationCreateSchema = v.object({
	email: v.pipe(v.string(), v.email('Please enter a valid email address.')),
	invitationType: v.picklist(['workshop', 'admin'], 'Please select a valid invitation type.'),
	waitlistId: v.optional(v.string()),
	expiresAt: v.optional(v.date()),
	metadata: v.optional(v.record(v.string(), v.unknown())),
	userId: v.pipe(v.string(), v.uuid('Please provide a valid user ID.')),
	firstName: v.pipe(v.string(), v.nonEmpty('First name is required.')),
	lastName: v.pipe(v.string(), v.nonEmpty('Last name is required.')),
	dateOfBirth: v.pipe(v.string(), v.nonEmpty('Date of birth is required.')),
	phoneNumber: v.pipe(v.string(), v.nonEmpty('Phone number is required.'))
});

export type InvitationCreateInput = v.InferOutput<typeof InvitationCreateSchema>;

/**
 * Schema for updating invitation status
 */
export const InvitationStatusUpdateSchema = v.object({
	invitationId: v.pipe(v.string(), v.uuid('Please provide a valid invitation ID.')),
	status: v.picklist(['pending', 'accepted', 'expired', 'revoked'], 'Please select a valid status.')
});

export type InvitationStatusUpdateInput = v.InferOutput<typeof InvitationStatusUpdateSchema>;

// ============================================================================
// Invitation Service
// ============================================================================

export class InvitationService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session | null,
		logger?: Logger
	) {
		this.logger = logger ?? console;
	}

	/**
	 * Throws if session is required but not present
	 */
	private requireSession(): Session {
		if (!this.session) {
			throw new Error('Session required for this operation', {
				cause: { context: 'InvitationService.requireSession' }
			});
		}
		return this.session;
	}

	// ========================================================================
	// Query Methods
	// ========================================================================

	/**
	 * Get invitation info by invitation ID using get_invitation_info RPC function
	 * This function validates the invitation and returns user profile data
	 */
	async getInvitationInfo(invitationId: string): Promise<InvitationInfo> {
		this.logger.info('Fetching invitation info', { invitationId });

		const result = await sql<{
			get_invitation_info: InvitationInfo;
		}>`
			select * from get_invitation_info(${invitationId}::uuid)
		`
			.execute(this.kysely)
			.then((r) => r.rows[0]?.get_invitation_info);

		if (!result) {
			throw new Error('Invitation not found', {
				cause: { invitationId, context: 'InvitationService.getInvitationInfo' }
			});
		}

		return result;
	}

	/**
	 * Get invitation by ID from invitations table
	 */
	async findById(invitationId: string): Promise<Invitation> {
		this.logger.info('Fetching invitation by ID', { invitationId });

		const session = this.requireSession();
		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			return this._findById(trx, invitationId);
		});
	}

	/**
	 * Get all invitations with optional filters
	 */
	async findMany(filters?: {
		status?: InvitationStatus;
		email?: string;
		userId?: string;
		invitationType?: InvitationType;
	}): Promise<Invitation[]> {
		this.logger.info('Fetching invitations', { filters });

		const session = this.requireSession();
		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			let query = trx.selectFrom('invitations').selectAll();

			if (filters?.status) {
				query = query.where('status', '=', filters.status);
			}
			if (filters?.email) {
				query = query.where('email', '=', filters.email);
			}
			if (filters?.userId) {
				query = query.where('user_id', '=', filters.userId);
			}
			if (filters?.invitationType) {
				query = query.where('invitation_type', '=', filters.invitationType);
			}

			return query.execute();
		});
	}

	// ========================================================================
	// Mutation Methods
	// ========================================================================

	/**
	 * Create a new invitation using the create_invitation RPC function
	 * This function also creates a user profile and assigns the member role
	 */
	async create(input: InvitationCreateInput): Promise<string> {
		this.logger.info('Creating invitation', { email: input.email });

		const session = this.requireSession();
		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			return this._create(trx, input);
		});
	}

	/**
	 * Update invitation status using the update_invitation_status RPC function
	 */
	async updateStatus(invitationId: string, status: InvitationStatus): Promise<boolean> {
		this.logger.info('Updating invitation status', { invitationId, status });

		const session = this.requireSession();
		return executeWithRLS(this.kysely, { claims: session }, async (trx) => {
			return this._updateStatus(trx, invitationId, status);
		});
	}

	/**
	 * Validate invitation (check if it exists, is pending, and not expired)
	 */
	async validate(invitationId: string): Promise<boolean> {
		this.logger.info('Validating invitation', { invitationId });

		try {
			const info = await this.getInvitationInfo(invitationId);
			return info.status === 'pending';
		} catch (error) {
			this.logger.warn('Invitation validation failed', { invitationId, error });
			return false;
		}
	}

	/**
	 * Validate invitation credentials by checking email and date of birth
	 * Returns true if the invitation exists, is pending, and credentials match
	 */
	async validateCredentials(
		invitationId: string,
		email: string,
		dateOfBirth: string
	): Promise<boolean> {
		this.logger.info('Validating invitation credentials', { invitationId, email });

		const result = await this.kysely
			.selectFrom('invitations')
			.leftJoin('user_profiles', 'user_profiles.supabase_user_id', 'invitations.user_id')
			.select(['invitations.id'])
			.where('invitations.id', '=', invitationId)
			.where('email', '=', email)
			.where('status', '=', 'pending')
			.where('user_profiles.date_of_birth', '=', dayjs(dateOfBirth).format('YYYY-MM-DD'))
			.executeTakeFirst();

		return !!result?.id;
	}

	/**
	 * Process invitation acceptance within an existing transaction
	 * This method handles the complete member registration flow without requiring a session
	 * 
	 * @param trx - Active database transaction
	 * @param invitationId - ID of the invitation to process
	 * @param nextOfKinName - Next of kin name
	 * @param nextOfKinPhone - Next of kin phone number
	 * @returns InvitationInfo for the processed invitation
	 */
	async processInvitationAcceptance(
		trx: Transaction<KyselyDatabase>,
		invitationId: string,
		nextOfKinName: string,
		nextOfKinPhone: string
	): Promise<InvitationInfo> {
		this.logger.info('Processing invitation acceptance', { invitationId });

		// Get invitation info first
		const invitationData = await this.getInvitationInfo(invitationId);

		// Update invitation status to accepted
		await this._updateStatus(trx, invitationData.invitation_id, 'accepted');

		// Complete member registration and update waitlist in parallel
		await Promise.all([
			sql<string>`
				select * from complete_member_registration(
					${invitationData.user_id}::uuid,
					${nextOfKinName}::text,
					${nextOfKinPhone}::text,
					${true}
				)
			`.execute(trx),
			trx
				.updateTable('waitlist')
				.set({ status: 'joined' })
				.where('email', '=', invitationData.email)
				.execute()
		]);

		return invitationData;
	}

	// ========================================================================
	// Private Transactional Methods (for cross-service coordination)
	// ========================================================================

	/**
	 * Internal transactional method for fetching invitation by ID
	 */
	async _findById(trx: Transaction<KyselyDatabase>, invitationId: string): Promise<Invitation> {
		const invitation = await trx
			.selectFrom('invitations')
			.selectAll()
			.where('id', '=', invitationId)
			.executeTakeFirst();

		if (!invitation) {
			throw new Error('Invitation not found', {
				cause: { invitationId, context: 'InvitationService._findById' }
			});
		}

		return invitation;
	}

	/**
	 * Internal transactional method for creating an invitation
	 */
	async _create(trx: Transaction<KyselyDatabase>, input: InvitationCreateInput): Promise<string> {
		const args: CreateInvitationArgs = {
			v_user_id: input.userId,
			p_email: input.email,
			p_first_name: input.firstName,
			p_last_name: input.lastName,
			p_date_of_birth: input.dateOfBirth,
			p_phone_number: input.phoneNumber,
			p_invitation_type: input.invitationType,
			p_waitlist_id: input.waitlistId,
			p_expires_at: input.expiresAt ? input.expiresAt.toISOString() : undefined,
			p_metadata: input.metadata as { [key: string]: string } | undefined
		};

		const result = await sql<{
			create_invitation: string;
		}>`
			select * from create_invitation(
				${args.v_user_id}::uuid,
				${args.p_email}::text,
				${args.p_first_name}::text,
				${args.p_last_name}::text,
				${args.p_date_of_birth}::timestamptz,
				${args.p_phone_number}::text,
				${args.p_invitation_type}::text,
				${args.p_waitlist_id ?? null}::uuid,
				${args.p_expires_at ?? null}::timestamptz,
				${args.p_metadata ? JSON.stringify(args.p_metadata) : null}::jsonb
			)
		`
			.execute(trx)
			.then((r) => r.rows[0]?.create_invitation);

		if (!result) {
			throw new Error('Failed to create invitation', {
				cause: { email: input.email, context: 'InvitationService._create' }
			});
		}

		return result;
	}

	/**
	 * Internal transactional method for updating invitation status
	 */
	async _updateStatus(
		trx: Transaction<KyselyDatabase>,
		invitationId: string,
		status: InvitationStatus
	): Promise<boolean> {
		const result = await sql<{
			update_invitation_status: boolean;
		}>`
			select * from update_invitation_status(
				${invitationId}::uuid,
				${status}::invitation_status
			)
		`
			.execute(trx)
			.then((r) => r.rows[0]?.update_invitation_status);

		if (result === undefined) {
			throw new Error('Failed to update invitation status', {
				cause: {
					invitationId,
					status,
					context: 'InvitationService._updateStatus'
				}
			});
		}

		return result;
	}
}
