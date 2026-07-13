import * as Sentry from "@sentry/sveltekit";
import { error, isHttpError } from "@sveltejs/kit";
import { getNextBillingDates } from "$lib/server/pricingUtils";
import { apiBaseUrl } from "$lib/server/api-client";
import { invitationsShowPublic } from "@dhc/api-client";
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
			...getNextBillingDates(),
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
