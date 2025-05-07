import type { RequestHandler } from "./$types";
import { jwtDecode } from "jwt-decode";
import dayjs from "dayjs";
import { invariant } from "$lib/server/invariant";
import { getKyselyClient } from "$lib/server/kysely";
import { getExistingPaymentSession } from "$lib/server/subscriptionCreation";
import { error } from "@sveltejs/kit";
import type { SubscriptionWithPlan } from "$lib/types";
import { generatePricingInfo } from "$lib/server/pricingUtils";

export const GET: RequestHandler = async ({ cookies, platform }) => {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const accessToken = cookies.get("access-token");
	invariant(
		accessToken === null,
		"There has been an error with your signup.",
	);
	const tokenClaim = jwtDecode(accessToken!);
	invariant(
		dayjs.unix(tokenClaim.exp!).isBefore(dayjs()),
		"This invitation has expired",
	);
	const userId = tokenClaim.sub!;
	// Get existing payment session data
	const paymentSession = await getExistingPaymentSession(userId, kysely);

	if (!paymentSession) {
		throw error(404, "Invalid invitation");
	}

	// Create the pricing info directly from the payment session data
	// We need to create objects that match the structure expected by generatePricingInfo
	const monthlySubscription = {
		plan: {
			amount: paymentSession.monthly_amount,
		},
	} as unknown as SubscriptionWithPlan;

	const annualSubscription = {
		plan: {
			amount: paymentSession.annual_amount,
		},
	} as unknown as SubscriptionWithPlan;

	// Generate and return pricing info using only the payment session data
	return Response.json(
		generatePricingInfo(
			monthlySubscription,
			annualSubscription,
			paymentSession.monthly_amount,
			paymentSession.annual_amount,
			paymentSession
		)
	);
};
