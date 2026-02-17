import type Stripe from "stripe";
import dayjs from "dayjs";
import type { Kysely, KyselyDatabase, Session, Logger } from "../shared";
import { executeWithRLS } from "../shared";
import { MEMBERSHIP_FEE_LOOKUP_NAME } from "$lib/server/constants";

export class SubscriptionService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		private stripe: Stripe,
		logger?: Logger,
	) {
		this.logger = logger ?? console;
	}

	async pause(
		memberId: string,
		pauseUntil: Date,
	): Promise<Stripe.Subscription> {
		this.logger.info("Pausing subscription", { memberId, pauseUntil });

		const pauseDate = dayjs(pauseUntil);

		const member = await this.kysely
			.selectFrom("member_management_view")
			.select(["customer_id", "subscription_paused_until"])
			.where("id", "=", memberId)
			.executeTakeFirst();

		if (!member?.customer_id) {
			throw new Error("Member or customer not found", {
				cause: { memberId, context: "SubscriptionService.pause" },
			});
		}

		const subscriptions = await this.stripe.subscriptions.list({
			customer: member.customer_id,
			status: "active",
			limit: 10,
		});

		const membershipSub = subscriptions.data.find((sub) =>
			sub.items.data.some(
				(item) => item.price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME,
			),
		);

		if (!membershipSub) {
			throw new Error("Active membership subscription not found", {
				cause: {
					memberId,
					customerId: member.customer_id,
					context: "SubscriptionService.pause",
				},
			});
		}

		const updatedSub = await this.stripe.subscriptions.update(
			membershipSub.id,
			{
				pause_collection: {
					behavior: "void",
					resumes_at: pauseDate.unix(),
				},
				expand: ["pause_collection"],
			},
		);

		if (updatedSub.pause_collection === null) {
			throw new Error("Failed to pause subscription in Stripe", {
				cause: {
					memberId,
					subscriptionId: membershipSub.id,
					context: "SubscriptionService.pause",
				},
			});
		}

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				await trx
					.updateTable("member_profiles")
					.set({ subscription_paused_until: pauseDate.toISOString() })
					.where("id", "=", memberId)
					.execute();

				return updatedSub;
			},
		);
	}

	async resume(memberId: string): Promise<Stripe.Subscription> {
		this.logger.info("Resuming subscription", { memberId });

		const member = await this.kysely
			.selectFrom("member_management_view")
			.select(["customer_id", "subscription_paused_until"])
			.where("id", "=", memberId)
			.executeTakeFirst();

		if (!member?.customer_id) {
			throw new Error("Member or customer not found", {
				cause: { memberId, context: "SubscriptionService.resume" },
			});
		}

		if (!member.subscription_paused_until) {
			throw new Error("Subscription is not paused", {
				cause: { memberId, context: "SubscriptionService.resume" },
			});
		}

		const subscriptions = await this.stripe.subscriptions.list({
			customer: member.customer_id,
			limit: 10,
		});

		const membershipSub = subscriptions.data.find(
			(sub) =>
				sub.items.data.some(
					(item) => item.price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME,
				) && sub.pause_collection !== null,
		);

		if (!membershipSub) {
			throw new Error("Paused membership subscription not found", {
				cause: {
					memberId,
					customerId: member.customer_id,
					context: "SubscriptionService.resume",
				},
			});
		}

		const updatedSub = await this.stripe.subscriptions.update(
			membershipSub.id,
			{
				pause_collection: null,
			},
		);

		return executeWithRLS(
			this.kysely,
			{ claims: this.session },
			async (trx) => {
				await trx
					.updateTable("member_profiles")
					.set({ subscription_paused_until: null })
					.where("id", "=", memberId)
					.execute();

				return updatedSub;
			},
		);
	}
}
