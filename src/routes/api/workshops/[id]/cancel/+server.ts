import * as Sentry from "@sentry/sveltekit";
import { json } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import { createWorkshopService } from "$lib/server/services/workshops";
import type { RequestHandler } from "./$types";

export const POST: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const workshopService = createWorkshopService(platform!, session);
		const workshop = await workshopService.cancel(params.id!);

		return json({ success: true, workshop });
	} catch (error) {
		Sentry.captureException(error);
		console.error("Cancel workshop error:", error);
		return json(
			{
				success: false,
				error: error instanceof Error ? error.message : "Unknown error",
			},
			{ status: 500 },
		);
	}
};
