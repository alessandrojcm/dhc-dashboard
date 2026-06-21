import { error } from "@sveltejs/kit";
import { workshopsAttendees } from "@dhc/api-client";
import { apiClientOptions } from "$lib/server/api-client";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async ({ params, locals }) => {
	const { session } = await locals.safeGetSession();

	if (!session) {
		error(401, { message: "Unauthorized" });
	}

	// Single Phoenix read (`GET /api/workshops/{id}/attendees`) returning the
	// combined Workshop summary + attendees + refunds payload. Phoenix enforces
	// coordinator RBAC (`workshop_coordinator` / `president` / `admin`) via the
	// `workshop_management_api` pipeline, so no SvelteKit `authorize()` role gate
	// is needed here — see commit 389a54ae and ADR 0005. The historical
	// `beginners_coordinator` registration visibility drift is NOT reproduced
	// (Phoenix 403s it). The Supabase JWT is attached by `apiClientOptions`.
	const {
		data,
		error: apiError,
		response,
	} = await workshopsAttendees({
		...apiClientOptions(session),
		path: { id: params.id },
	});

	if (apiError) {
		// Surface Phoenix's 404 (missing Workshop) and 403 (insufficient role)
		// to the user; fall back to 503 for auth/network/5xx failures.
		if (response?.status === 404) {
			error(404, { message: "Workshop not found" });
		}
		if (response?.status === 403) {
			error(403, { message: "Insufficient role" });
		}
		error(503, { message: "Unable to load workshop attendees" });
	}

	// `data` is the full `WorkshopAttendeesResponse` envelope
	// (`{ data: { workshop, attendees, refunds } }`). Returned verbatim as
	// `initialData` for the client-side TanStack Query so SSR and refetch share
	// one shape.
	return {
		attendeesResponse: data,
	};
};
