import * as Sentry from "@sentry/sveltekit";
import { json } from "@sveltejs/kit";
import { authorize } from "$lib/server/auth";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import { publishWorkshop } from "$lib/server/workshops";
import type { RequestHandler } from "./$types";

export const POST: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const workshop = await publishWorkshop(params.id!, session, platform!);

		return json({ success: true, workshop });
	} catch (error) {
		Sentry.captureException(error);
		console.error("Publish workshop error:", error);
		return json(
			{
				success: false,
				error: error instanceof Error ? error.message : "Unknown error",
			},
			{ status: 500 },
		);
	}
};
