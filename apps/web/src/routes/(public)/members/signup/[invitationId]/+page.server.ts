import { onboardingShowInvitationAcceptance } from "@dhc/api-client";
import { dev } from "$app/environment";
import {
	clearInvitationAcceptanceProof,
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
} from "$lib/server/invitation-acceptance-proof";
import dayjs from "dayjs";
import { redirect } from "@sveltejs/kit";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, cookies }) => {
	if (!hasInvitationAcceptanceProof(cookies)) {
		return {
			state: "restart_verification" as const,
			nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
			nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
		};
	}

	const response = await onboardingShowInvitationAcceptance(
		invitationAcceptanceApiOptions(cookies),
	);
	if (response.data?.data?.state === "accepted") {
		setSignInPrefill(cookies, response.data.data.invitationEmail);
		clearInvitationAcceptanceProof(cookies);
		throw redirect(303, `/members/signup/${params.invitationId}/success`);
	}
	if (
		response.data?.data?.state === "restart_verification" ||
		response.response?.status === 409
	) {
		clearInvitationAcceptanceProof(cookies);
	}

	return {
		...response.data?.data,
		state: response.data?.data?.state ?? ("restart_verification" as const),
		nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
		nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
	};
};

function setSignInPrefill(
	cookies: Parameters<PageServerLoad>[0]["cookies"],
	email: string | undefined,
) {
	if (!email) return;
	cookies.set("invitation-sign-in-prefill", email, {
		path: "/auth",
		httpOnly: true,
		secure: !dev,
		sameSite: "lax",
		maxAge: 10 * 60,
	});
}
