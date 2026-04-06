import { error } from "@sveltejs/kit";
import * as v from "valibot";
import { createPublicRegistrationService } from "$lib/server/services/workshops";
import type { PageServerLoad } from "./$types";

/**
 * Load function for public workshop registration page.
 *
 * This implements the gating logic described in Stage 3B:
 * - Validates workshop ID as UUID
 * - Fetches gate state from registration service
 * - Returns 404 for unavailable workshops
 * - Returns 200 with generic message for full workshops (no details)
 * - Returns 200 with workshop payload for eligible workshops
 */
export const load: PageServerLoad = async ({ params, platform }) => {
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
				// Full workshop returns 200 with generic message only, no details
				return {
					canRegister: false,
					message: "This workshop is full",
				};
		}
	}

	// Workshop is eligible - return full details
	return {
		canRegister: true,
		workshop: gateStatus.workshop!,
	};
};
