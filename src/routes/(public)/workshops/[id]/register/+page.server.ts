import { error, redirect } from "@sveltejs/kit";
import * as v from "valibot";
import { createPublicRegistrationService } from "$lib/server/services/workshops";
import type { ExternalRegistrationError } from "$lib/server/services/workshops";
import type { PageServerLoad } from "./$types";

/**
 * Load function for public workshop registration page.
 *
 * This implements the gating logic described in Stage 3B:
 * - Validates workshop ID as UUID
 * - Fetches gate state from registration service
 * - Returns 404 for unavailable workshops
 * - Redirects full workshops to /workshops/[id]/full
 * - Returns workshop payload for eligible workshops
 */
export const load: PageServerLoad = async ({ params, platform, url }) => {
	// Validate workshop ID
	const workshopIdResult = v.safeParse(v.pipe(v.string(), v.uuid()), params.id);

	if (!workshopIdResult.success) {
		error(404, "Workshop not found");
	}

	const workshopId = workshopIdResult.output;

	// Check eligibility using public registration service
	const registrationService = createPublicRegistrationService(platform!);
	const gateStatus =
		await registrationService.getExternalRegistrationGate(workshopId);

	// Handle different gate states according to Stage 3B contract
	if (!gateStatus.canRegister) {
		switch (gateStatus.reason) {
			case "NOT_FOUND":
			case "NOT_PUBLISHED":
			case "NOT_PUBLIC":
			case "NO_EXTERNAL_PRICE":
				// These states return 404 - workshop unavailable for registration
				error(404, "Workshop not found");
				break;

			case "FULL":
				redirect(303, `/workshops/${workshopId}/full`);
		}
	}

	const returnUrl = `${url.origin}/workshops/${workshopId}/confirmation?session_id={CHECKOUT_SESSION_ID}`;

	try {
		const checkoutSession =
			await registrationService.createExternalCheckoutSession({
				workshopId,
				returnUrl,
			});

		return {
			workshop: gateStatus.workshop!,
			checkoutSessionId: checkoutSession.checkoutSessionId,
			checkoutClientSecret: checkoutSession.checkoutClientSecret,
		};
	} catch (err) {
		const domainError = err as ExternalRegistrationError;

		if (domainError.name === "ExternalRegistrationError") {
			if (domainError.code === "WORKSHOP_FULL") {
				redirect(303, `/workshops/${workshopId}/full`);
			}

			if (domainError.code === "WORKSHOP_NOT_FOUND") {
				error(404, "Workshop not found");
			}
		}

		throw err;
	}
};
