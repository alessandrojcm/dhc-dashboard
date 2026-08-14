import { onboardingShowAcceptance } from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";
import dayjs from "dayjs";
import { redirect } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, cookies }) => {
	const proof = cookies.get(`onboarding-acceptance-${params.invitationId}`);

	if (!proof) {
		return {
			state: "restartVerification" as const,
			nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
			nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
		};
	}

	const response = await onboardingShowAcceptance({
		baseUrl: apiBaseUrl(),
		headers: {
			"x-onboarding-continuation": proof,
		},
	});
	if (response.data?.data?.state === "accepted") {
		cookies.delete(`onboarding-acceptance-${params.invitationId}`, {
			path: "/",
		});
		throw redirect(303, `/members/signup/${params.invitationId}/success`);
	}

	return {
		state: response.data?.data?.state ?? ("restartVerification" as const),
		invitationEmail: response.data?.data?.invitationEmail,
		discord: response.data?.data?.discord,
		discordVerified: response.data?.data?.discordVerified,
		retryAllowed: response.data?.data?.retryAllowed,
		nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
		nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
	};
};
