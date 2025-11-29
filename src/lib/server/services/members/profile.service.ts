/**
 * Profile Service
 * Handles member profile updates with external system integration (Stripe)
 */

import type Stripe from "stripe";
import type { Kysely, KyselyDatabase, Session, Logger } from "../shared";
import { executeWithRLS } from "../shared";
import {
	MemberService,
	type MemberUpdateInput,
	type MemberData,
} from "./member.service";

// ============================================================================
// Profile Service
// ============================================================================

/**
 * Profile Service coordinates member profile updates with external systems
 * Depends on MemberService for database operations and Stripe for payment sync
 */
export class ProfileService {
	private logger: Logger;
	private memberService: MemberService;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		private stripe: Stripe,
		logger?: Logger,
		memberService?: MemberService,
	) {
		this.logger = logger ?? console;
		this.memberService =
			memberService ?? new MemberService(kysely, session, logger);
	}

	/**
	 * Update member profile and sync with Stripe
	 * This is the main entry point for profile updates from the UI
	 */
	async updateProfile(
		userId: string,
		input: MemberUpdateInput,
	): Promise<MemberData> {
		this.logger.info("Updating member profile with external sync", { userId });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				// Get current user data for comparison
				const currentUser = await this.memberService._getCurrentProfile(
					trx,
					userId,
				);

				if (!currentUser?.customer_id) {
					throw new Error("Customer ID not found", {
						cause: { userId, context: "ProfileService.updateProfile" },
					});
				}

				// Update member data in database
				const updatedMember = await this.memberService._update(
					trx,
					userId,
					input,
				);

				// Check if name or phone number changed
				const currentName =
					`${currentUser.first_name ?? ""} ${currentUser.last_name ?? ""}`.trim();
				const newName = `${input.firstName} ${input.lastName}`.trim();
				const nameChanged = currentName !== newName;
				const phoneChanged = currentUser.phone_number !== input.phoneNumber;

				// Only update Stripe if necessary
				if (nameChanged || phoneChanged) {
					this.logger.info("Syncing changes to Stripe", {
						userId,
						nameChanged,
						phoneChanged,
					});

					await this.stripe.customers.update(currentUser.customer_id, {
						...(nameChanged && { name: newName }),
						...(phoneChanged && { phone: input.phoneNumber }),
					});
				}

				return updatedMember;
			},
		);
	}

	/**
	 * Pause member subscription
	 */
	async pauseSubscription(userId: string, until: Date): Promise<void> {
		this.logger.info("Pausing subscription", { userId, until });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				await trx
					.updateTable("member_profiles")
					.set({ subscription_paused_until: until.toISOString() })
					.where("user_profile_id", "=", userId)
					.execute();
			},
		);
	}

	/**
	 * Resume member subscription
	 */
	async resumeSubscription(userId: string): Promise<void> {
		this.logger.info("Resuming subscription", { userId });

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				await trx
					.updateTable("member_profiles")
					.set({ subscription_paused_until: null })
					.where("user_profile_id", "=", userId)
					.execute();
			},
		);
	}
}
