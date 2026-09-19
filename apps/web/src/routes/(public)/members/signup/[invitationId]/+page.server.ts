import dayjs from "dayjs";
import {
	applyInvitationRouteOutcome,
	invitationAcceptanceDeps,
	readInvitationPage,
} from "$lib/server/invitation-acceptance";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, cookies }) => {
	const deps = invitationAcceptanceDeps(cookies);
	const view = applyInvitationRouteOutcome(await readInvitationPage(deps), {
		cookies: deps.cookies,
		invitationId: params.invitationId,
		mode: "render",
	});

	return {
		...view,
		nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
		nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
	};
};
