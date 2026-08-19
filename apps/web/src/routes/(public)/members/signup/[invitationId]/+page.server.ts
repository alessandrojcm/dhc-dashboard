import { onboardingShowInvitationAcceptance } from "@dhc/api-client";
import {
	clearInvitationAcceptanceProof,
	hasInvitationAcceptanceProof,
	invitationAcceptanceApiOptions,
} from "$lib/server/invitation-acceptance-proof";
import { completeInvitationAcceptance } from "$lib/server/post-acceptance-sign-in-handoff";
import dayjs from "dayjs";
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
		completeInvitationAcceptance(
			cookies,
			response.data.data.invitationEmail,
			params.invitationId,
		);
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
