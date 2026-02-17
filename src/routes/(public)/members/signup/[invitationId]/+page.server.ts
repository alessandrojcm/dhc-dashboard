import * as Sentry from "@sentry/sveltekit";
import { error } from "@sveltejs/kit";
import { getNextBillingDates } from "$lib/server/pricingUtils";
import { createInvitationService } from "$lib/server/services/invitations";
import type { PageServerLoad } from "./$types";
// TODO: fix page not reloading when invitation is confirmed, fix test
export const load: PageServerLoad = async ({ params, platform, cookies }) => {
	const invitationId = params.invitationId;
	const isConfirmed = Boolean(cookies.get(`invite-confirmed-${invitationId}`));

	try {
		// Create invitation service without session (public route)
		const invitationService = createInvitationService(platform!);

		// Get invitation data first (essential for page rendering)
		const invitationData =
			await invitationService.getInvitationInfo(invitationId);

		if (!invitationData) {
			return error(404, "Invitation not found");
		}

		// Return essential data immediately, with pricing as a streamed promise
		return {
			userData: {
				firstName: invitationData.first_name,
				lastName: invitationData.last_name,
				email: invitationData.email,
				dateOfBirth: new Date(invitationData.date_of_birth),
				phoneNumber: invitationData.phone_number,
				pronouns: invitationData.pronouns,
				gender: invitationData.gender,
				medicalConditions: invitationData.medical_conditions,
			},
			isConfirmed,
			insuranceFormLink: "",
			// These are needed for the page but can be calculated immediately
			...getNextBillingDates(),
		};
	} catch (err) {
		console.error("[+page.server.ts] Load error:", err);
		Sentry.captureException(err);
		error(404, {
			message: "Something went wrong",
		});
	}
};
