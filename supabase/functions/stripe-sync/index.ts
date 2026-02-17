import dayjs from "npm:dayjs";
import * as Sentry from "@sentry/deno";
import { Stripe } from "stripe";
import { corsHeaders } from "../_shared/cors.ts";
import { db } from "../_shared/db.ts";

Sentry.init({
	dsn: Deno.env.get("SENTRY_DSN"),
	environment: Deno.env.get("ENVIRONMENT") || "development",
});

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "", {
	apiVersion: "2025-10-29.clover",
	maxNetworkRetries: 3,
	timeout: 30 * 1000,
	httpClient: Stripe.createFetchHttpClient(),
});

const MEMBERSHIP_LOOKUP_KEY = "standard_membership_fee";
const MONTHLY_PRICE_SETTING_KEY = "stripe_monthly_price_id";
const INACTIVE_STATUSES = new Set<Stripe.Subscription.Status>([
	"canceled",
	"incomplete_expired",
	"unpaid",
]);

type SyncRequestBody = {
	customer_ids?: string[];
};

type SyncSummary = {
	targetCustomers: number;
	stripeSubscriptionsScanned: number;
	processed: number;
	updated: number;
	failed: number;
	inactive: number;
	paused: number;
	active: number;
	unchanged: number;
};

type SyncAction = "inactive" | "paused" | "active" | "unchanged";

type StripeSyncExecutor = Pick<typeof db, "updateTable" | "selectFrom">;

async function setUserInactive(
	executor: StripeSyncExecutor,
	customerId: string,
): Promise<void> {
	await executor
		.updateTable("user_profiles")
		.set({ is_active: false })
		.where("customer_id", "=", customerId)
		.execute();
}

async function getTargetCustomerIds(
	requestCustomerIds?: string[],
): Promise<string[]> {
	if (requestCustomerIds && requestCustomerIds.length > 0) {
		return Array.from(
			new Set(
				requestCustomerIds
					.map((customerId) => customerId.trim())
					.filter((customerId) => customerId.length > 0),
			),
		);
	}

	const staleBefore = dayjs().subtract(1, "day").toDate();
	const rows = await db
		.selectFrom("user_profiles as up")
		.innerJoin("member_profiles as mp", "mp.user_profile_id", "up.id")
		.select("up.customer_id")
		.where("up.customer_id", "is not", null)
		.where("up.customer_id", "!=", "")
		.where((eb) =>
			eb.or([
				eb("mp.updated_at", "is", null),
				eb("mp.updated_at", "<", staleBefore),
			]),
		)
		.execute();

	return rows
		.map((row) => row.customer_id)
		.filter((customerId): customerId is string => customerId !== null);
}

async function getMembershipPriceId(): Promise<string> {
	const cached = await db
		.selectFrom("settings")
		.select(["value", "updated_at"])
		.where("key", "=", MONTHLY_PRICE_SETTING_KEY)
		.executeTakeFirst();

	if (cached?.value && cached.updated_at) {
		const isFresh = dayjs().diff(dayjs(cached.updated_at), "hour") <= 24;
		if (isFresh) {
			return cached.value;
		}
	}

	const prices = await stripe.prices.list({
		lookup_keys: [MEMBERSHIP_LOOKUP_KEY],
		active: true,
		limit: 1,
	});

	if (!prices.data[0]) {
		throw new Error(
			`No Stripe price found for lookup key: ${MEMBERSHIP_LOOKUP_KEY}`,
		);
	}

	const priceId = prices.data[0].id;
	await db.transaction().execute(async (trx) => {
		await trx
			.updateTable("settings")
			.set({
				value: priceId,
				updated_at: new Date().toISOString(),
			})
			.where("key", "=", MONTHLY_PRICE_SETTING_KEY)
			.execute();
	});

	return priceId;
}

async function getLatestMembershipSubscriptionByCustomer(
	priceId: string,
	targetCustomerIds: Set<string>,
): Promise<{
	latestByCustomer: Map<string, Stripe.Subscription>;
	scanned: number;
}> {
	const latestByCustomer = new Map<string, Stripe.Subscription>();
	let scanned = 0;
	let startingAfter: string | undefined;

	while (true) {
		const page = await stripe.subscriptions.list({
			status: "all",
			price: priceId,
			limit: 100,
			starting_after: startingAfter,
		});

		scanned += page.data.length;

		for (const subscription of page.data) {
			const customerId =
				typeof subscription.customer === "string"
					? subscription.customer
					: subscription.customer.id;

			if (!targetCustomerIds.has(customerId)) {
				continue;
			}

			const existing = latestByCustomer.get(customerId);
			if (!existing || subscription.created > existing.created) {
				latestByCustomer.set(customerId, subscription);
			}
		}

		if (!page.has_more || page.data.length === 0) {
			break;
		}

		startingAfter = page.data[page.data.length - 1]?.id;
		if (!startingAfter) {
			break;
		}
	}

	return { latestByCustomer, scanned };
}

async function syncCustomer(
	customerId: string,
	standardMembershipSub: Stripe.Subscription | undefined,
): Promise<SyncAction> {
	return db.transaction().execute(async (trx) => {
		if (
			!standardMembershipSub ||
			INACTIVE_STATUSES.has(standardMembershipSub.status)
		) {
			await setUserInactive(trx, customerId);
			return "inactive";
		}

		if (standardMembershipSub.pause_collection !== null) {
			const resumeDate = standardMembershipSub.pause_collection?.resumes_at
				? dayjs.unix(standardMembershipSub.pause_collection.resumes_at).toDate()
				: null;

			await trx
				.updateTable("member_profiles")
				.set({ subscription_paused_until: resumeDate })
				.where(
					"user_profile_id",
					"in",
					trx
						.selectFrom("user_profiles")
						.select("id")
						.where("customer_id", "=", customerId),
				)
				.execute();

			console.log(
				`Subscription paused for customer: ${customerId} until ${resumeDate}`,
			);
			return "paused";
		}

		if (standardMembershipSub.status === "active") {
			await Promise.all([
				trx
					.updateTable("member_profiles")
					.set({
						subscription_paused_until: null,
						last_payment_date: dayjs
							.unix(standardMembershipSub.start_date)
							.toDate(),
						membership_end_date: standardMembershipSub.ended_at
							? dayjs.unix(standardMembershipSub.ended_at).toDate()
							: null,
					})
					.where(
						"user_profile_id",
						"in",
						trx
							.selectFrom("user_profiles")
							.select("id")
							.where("customer_id", "=", customerId),
					)
					.execute(),
				trx
					.updateTable("user_profiles")
					.set({ is_active: true })
					.where("customer_id", "=", customerId)
					.execute(),
			]);
			return "active";
		}

		return "unchanged";
	});
}

function captureCustomerSyncError(customerId: string, error: unknown) {
	console.error(`Error syncing Stripe data for customer ${customerId}:`, error);
	Sentry.withScope((scope) => {
		scope.setTag("function", "stripe-sync");
		scope.setTag("customer_id", customerId);
		Sentry.captureException(error);
	});
}

async function syncStripeDataToKV(
	requestCustomerIds?: string[],
): Promise<SyncSummary> {
	try {
		const targetCustomerIds = await getTargetCustomerIds(requestCustomerIds);
		if (targetCustomerIds.length === 0) {
			return {
				targetCustomers: 0,
				stripeSubscriptionsScanned: 0,
				processed: 0,
				updated: 0,
				failed: 0,
				inactive: 0,
				paused: 0,
				active: 0,
				unchanged: 0,
			};
		}

		const targetCustomerSet = new Set(targetCustomerIds);
		const priceId = await getMembershipPriceId();
		const { latestByCustomer, scanned } =
			await getLatestMembershipSubscriptionByCustomer(
				priceId,
				targetCustomerSet,
			);

		const summary: SyncSummary = {
			targetCustomers: targetCustomerIds.length,
			stripeSubscriptionsScanned: scanned,
			processed: 0,
			updated: 0,
			failed: 0,
			inactive: 0,
			paused: 0,
			active: 0,
			unchanged: 0,
		};

		for (const customerId of targetCustomerIds) {
			try {
				const action = await syncCustomer(
					customerId,
					latestByCustomer.get(customerId),
				);
				summary.processed += 1;
				summary[action] += 1;
				if (action !== "unchanged") {
					summary.updated += 1;
				}
			} catch (error) {
				summary.failed += 1;
				captureCustomerSyncError(customerId, error);
			}
		}

		return summary;
	} catch (error) {
		console.error("Error syncing Stripe data batch:", error);
		Sentry.captureException(error);
		throw error;
	}
}

async function verifyBearerToken(authHeader: string | null): Promise<boolean> {
	if (!authHeader || !authHeader.startsWith("Bearer ")) {
		return false;
	}

	const token = authHeader.substring(7);
	const serviceRoleKey =
		Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
		Deno.env.get("SERVICE_ROLE_KEY");
	return Boolean(serviceRoleKey) && token === serviceRoleKey;
}

Deno.serve(async (req) => {
	if (req.method === "OPTIONS") {
		return new Response("ok", { headers: corsHeaders });
	}

	try {
		if (!(await verifyBearerToken(req.headers.get("Authorization")))) {
			return new Response(JSON.stringify({ error: "Unauthorized" }), {
				status: 401,
				headers: { ...corsHeaders, "Content-Type": "application/json" },
			});
		}

		let payload: SyncRequestBody = {};
		try {
			payload = await req.json();
		} catch {
			payload = {};
		}

		if (payload.customer_ids && !Array.isArray(payload.customer_ids)) {
			return new Response(
				JSON.stringify({
					error: "customer_ids must be an array when provided",
				}),
				{
					status: 400,
					headers: { ...corsHeaders, "Content-Type": "application/json" },
				},
			);
		}

		if (
			payload.customer_ids &&
			payload.customer_ids.some((customerId) => typeof customerId !== "string")
		) {
			return new Response(
				JSON.stringify({
					error: "customer_ids must contain only strings",
				}),
				{
					status: 400,
					headers: { ...corsHeaders, "Content-Type": "application/json" },
				},
			);
		}

		const summary = syncStripeDataToKV(payload.customer_ids);
		EdgeRuntime.waitUntil(summary);

		return new Response(JSON.stringify({ success: true, summary }), {
			headers: { ...corsHeaders, "Content-Type": "application/json" },
			status: 200,
		});
	} catch (err) {
		console.error("Error syncing customer batch:", err);
		Sentry.captureException(err);
		return new Response(JSON.stringify({ error: (err as Error)?.message }), {
			headers: { ...corsHeaders, "Content-Type": "application/json" },
			status: 400,
		});
	}
});
