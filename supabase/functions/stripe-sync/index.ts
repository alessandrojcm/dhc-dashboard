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
const STRIPE_SYNC_DEBUG = Deno.env.get("STRIPE_SYNC_DEBUG") === "true";
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

function logInfo(message: string, context?: Record<string, unknown>) {
	if (context) {
		console.log(`[stripe-sync] ${message}`, context);
		return;
	}

	console.log(`[stripe-sync] ${message}`);
}

function logDebug(message: string, context?: Record<string, unknown>) {
	if (!STRIPE_SYNC_DEBUG) return;

	if (context) {
		console.log(`[stripe-sync:debug] ${message}`, context);
		return;
	}

	console.log(`[stripe-sync:debug] ${message}`);
}

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
		const deduped = Array.from(
			new Set(
				requestCustomerIds
					.map((customerId) => customerId.trim())
					.filter((customerId) => customerId.length > 0),
			),
		);

		logInfo("Using manually provided customer IDs", {
			inputCount: requestCustomerIds.length,
			targetCount: deduped.length,
		});

		logDebug("Manual customer IDs", {
			customerIds: deduped,
		});

		return deduped;
	}

	const staleBefore = dayjs().subtract(1, "day").toDate();
	logDebug("Selecting stale customers", {
		staleBefore: staleBefore.toISOString(),
	});

	const rows = await db
		.selectFrom("user_profiles as up")
		.innerJoin("member_profiles as mp", "mp.user_profile_id", "up.id")
		.select("up.customer_id")
		.where("up.customer_id", "is not", null)
		.where("up.customer_id", "!=", "")
		.where((eb) =>
			eb.or([
				eb("mp.last_payment_date", "is", null),
				eb("mp.last_payment_date", "<", staleBefore),
			]),
		)
		.execute();

	logInfo("Resolved stale customer IDs", {
		targetCount: rows.length,
		staleBefore: staleBefore.toISOString(),
	});

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
			logDebug("Using cached Stripe membership price ID", {
				priceId: cached.value,
				updatedAt: cached.updated_at,
			});
			return cached.value;
		}

		logInfo("Stripe membership price cache is stale", {
			updatedAt: cached.updated_at,
		});
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
	logInfo("Fetched Stripe membership price ID", { priceId });

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
	let pageNumber = 0;

	logInfo("Fetching Stripe subscriptions for target customers", {
		targetCustomers: targetCustomerIds.size,
		priceId,
	});

	while (true) {
		pageNumber += 1;
		const page = await stripe.subscriptions.list({
			status: "all",
			price: priceId,
			expand: ["data.latest_invoice"],
			limit: 100,
			starting_after: startingAfter,
		});

		scanned += page.data.length;
		logDebug("Processed Stripe subscriptions page", {
			pageNumber,
			pageSize: page.data.length,
			hasMore: page.has_more,
			scanned,
		});

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

	logInfo("Completed Stripe subscription scan", {
		scanned,
		matchedCustomers: latestByCustomer.size,
	});

	return { latestByCustomer, scanned };
}

function resolveLastPaymentDate(subscription: Stripe.Subscription): Date {
	const latestInvoice =
		typeof subscription.latest_invoice === "string" ||
		subscription.latest_invoice === null
			? null
			: subscription.latest_invoice;

	const paidAt = latestInvoice?.status_transitions?.paid_at ?? null;
	const paymentTimestamp = paidAt ?? subscription.start_date;

	return dayjs.unix(paymentTimestamp).toDate();
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
			logDebug("Marked customer inactive", {
				customerId,
				subscriptionStatus: standardMembershipSub?.status ?? "missing",
			});
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
			logDebug("Marked customer as paused", {
				customerId,
				resumeDate: resumeDate?.toISOString() ?? null,
			});
			return "paused";
		}

		if (standardMembershipSub.status === "active") {
			const lastPaymentDate = resolveLastPaymentDate(standardMembershipSub);

			await Promise.all([
				trx
					.updateTable("member_profiles")
					.set({
						subscription_paused_until: null,
						last_payment_date: lastPaymentDate,
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
			logDebug("Marked customer as active", {
				customerId,
				lastPaymentDate: lastPaymentDate.toISOString(),
			});
			return "active";
		}

		logDebug("No customer updates applied", {
			customerId,
			subscriptionStatus: standardMembershipSub.status,
		});

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
		logInfo("Starting stripe sync batch", {
			manualCustomerIdsProvided: Boolean(requestCustomerIds?.length),
			manualCustomerCount: requestCustomerIds?.length ?? 0,
		});

		const targetCustomerIds = await getTargetCustomerIds(requestCustomerIds);
		if (targetCustomerIds.length === 0) {
			logInfo("No target customers found for sync");

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

		logInfo("Completed stripe sync batch", {
			targetCustomers: summary.targetCustomers,
			stripeSubscriptionsScanned: summary.stripeSubscriptionsScanned,
			processed: summary.processed,
			updated: summary.updated,
			failed: summary.failed,
			inactive: summary.inactive,
			paused: summary.paused,
			active: summary.active,
			unchanged: summary.unchanged,
		});

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
		const requestId = crypto.randomUUID();
		logInfo("Received stripe sync request", {
			requestId,
			method: req.method,
		});

		if (!(await verifyBearerToken(req.headers.get("Authorization")))) {
			logInfo("Unauthorized stripe sync request", { requestId });

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
		logInfo("Stripe sync request accepted", {
			requestId,
			manualCustomerCount: payload.customer_ids?.length ?? 0,
		});

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
