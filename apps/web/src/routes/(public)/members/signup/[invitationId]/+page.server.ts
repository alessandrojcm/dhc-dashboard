import * as Sentry from "@sentry/sveltekit";
import { error, isHttpError } from "@sveltejs/kit";
import { apiBaseUrl } from "$lib/server/api-client";
import { invitationsShowPublic } from "@dhc/api-client";
import dayjs from "dayjs";
import type { PageServerLoad } from "./$types";

// TODO: fix page not reloading when invitation is confirmed, fix test
export const load: PageServerLoad = async ({ params, cookies }) => {
	const invitationId = params.invitationId;
	const isConfirmed = Boolean(cookies.get(`invite-confirmed-${invitationId}`));

	try {
		const response = await invitationsShowPublic({
			baseUrl: apiBaseUrl(),
			path: { id: invitationId },
		});

		if (response.error || !response.data?.data) {
			const status = response.response?.status === 404 ? 404 : 500;
			error(
				status,
				status === 404 ? "Invitation not found" : "Something went wrong",
			);
		}

		const invitation = response.data.data;

		return {
			invitation,
			isConfirmed,
			insuranceFormLink: "",
			nextMonthlyBillingDate: dayjs().add(1, "month").startOf("month").toDate(),
			nextAnnualBillingDate: dayjs().month(0).date(7).add(1, "year").toDate(),
		};
	} catch (err) {
		if (isHttpError(err)) {
			throw err;
		}

		console.error("[+page.server.ts] Load error:", err);
		Sentry.captureException(err);
		error(404, {
			message: "Something went wrong",
		});
	}
};
