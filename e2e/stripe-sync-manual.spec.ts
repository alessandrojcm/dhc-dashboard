import { expect, test } from "@playwright/test";
import { MEMBERSHIP_FEE_LOOKUP_NAME } from "../src/lib/server/constants";
import {
	createMember,
	createUniqueEmail,
	getSupabaseServiceClient,
	stripeClient,
} from "./setupFunctions";

async function invokeStripeSyncWithRetry(
	supabaseServiceClient: ReturnType<typeof getSupabaseServiceClient>,
	customerId: string,
) {
	let lastError = "Unknown stripe-sync invocation failure";

	for (let attempt = 1; attempt <= 3; attempt++) {
		const { data, error } = await supabaseServiceClient.functions.invoke(
			"stripe-sync",
			{
				body: { customer_ids: [customerId] },
			},
		);

		if (!error) {
			return data;
		}

		const context = (error as { context?: Response }).context;
		if (context instanceof Response) {
			const responseBody = await context.text();
			lastError = `${error.name}: ${context.status} ${responseBody || context.statusText}`;
		} else {
			lastError = `${error.name}: ${error.message}`;
		}
		console.warn(`stripe-sync attempt ${attempt} failed: ${lastError}`);

		if (attempt < 3) {
			await new Promise((resolve) => setTimeout(resolve, 1000 * attempt));
		}
	}

	throw new Error(`stripe-sync invocation failed after retries: ${lastError}`);
}

async function waitForUserActiveState(
	supabaseServiceClient: ReturnType<typeof getSupabaseServiceClient>,
	profileId: string,
	expectedIsActive: boolean,
) {
	let lastValue: boolean | null = null;

	for (let attempt = 1; attempt <= 20; attempt++) {
		const { data: syncedProfile, error: syncedProfileError } =
			await supabaseServiceClient
				.from("user_profiles")
				.select("is_active")
				.eq("id", profileId)
				.single();

		if (syncedProfileError) {
			throw syncedProfileError;
		}

		lastValue = syncedProfile.is_active;
		if (syncedProfile.is_active === expectedIsActive) {
			return syncedProfile;
		}

		await new Promise((resolve) => setTimeout(resolve, 1000));
	}

	throw new Error(
		`Timed out waiting for user is_active=${expectedIsActive}. Last value: ${lastValue}`,
	);
}

test.describe("Stripe sync manual flow", () => {
	test("marks member inactive after subscription cancellation", async () => {
		test.setTimeout(120_000);
		const supabaseServiceClient = getSupabaseServiceClient();
		const createdMember = await createMember({
			email: createUniqueEmail("stripe-sync-manual"),
			createSubscription: true,
			roles: new Set(["member"]),
		});

		try {
			const { data: userProfile, error: userProfileError } =
				await supabaseServiceClient
					.from("user_profiles")
					.select("customer_id")
					.eq("id", createdMember.profileId)
					.single();

			if (userProfileError) {
				throw userProfileError;
			}

			const customerId = userProfile.customer_id;
			if (!customerId) {
				throw new Error("Expected created member to have a Stripe customer_id");
			}

			const subscriptions = await stripeClient.subscriptions.list({
				customer: customerId,
				status: "all",
				limit: 100,
				expand: ["data.items.data.price"],
			});

			const membershipSubscription = subscriptions.data
				.filter((subscription) =>
					subscription.items.data.some((item) => {
						const price = item.price;
						return (
							typeof price !== "string" &&
							price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME
						);
					}),
				)
				.sort((left, right) => right.created - left.created)[0];

			if (!membershipSubscription) {
				throw new Error(
					`No ${MEMBERSHIP_FEE_LOOKUP_NAME} subscription found for ${customerId}`,
				);
			}

			await stripeClient.subscriptions.cancel(membershipSubscription.id);

			const payload = await invokeStripeSyncWithRetry(
				supabaseServiceClient,
				customerId,
			);
			expect(payload.success).toBe(true);

			const syncedProfile = await waitForUserActiveState(
				supabaseServiceClient,
				createdMember.profileId,
				false,
			);
			expect(syncedProfile.is_active).toBe(false);
		} finally {
			await createdMember.cleanUp();
		}
	});
});
