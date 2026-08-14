import { onboardingShowInvitationAcceptance } from "@dhc/api-client";
import { onboardingApiClientOptions } from "$lib/server/onboarding-api";
import dayjs from "dayjs";
import { redirect } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ cookies }) => {
	const proof = cookies.get("_dhc_onboarding_acceptance");

	if (!proof) {
		return {
			state: "restart_verification" as const,
			nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
			nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
		};
	}

	const response = await onboardingShowInvitationAcceptance(
		onboardingApiClientOptions(cookies),
	);

	return {
		state: response.data?.data?.state ?? ("restart_verification" as const),
		nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
		nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
	};
};
