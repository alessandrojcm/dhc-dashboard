import { error } from "@sveltejs/kit";
import * as v from "valibot";
import {
	completeExternalWorkshopRegistration,
	ExternalWorkshopRegistrationApiError,
} from "$lib/server/api/external-workshop-registration";

export const load = async ({
	params,
	url,
}: {
	params: { id: string };
	url: URL;
}) => {
	const workshopIdResult = v.safeParse(v.pipe(v.string(), v.uuid()), params.id);
	if (!workshopIdResult.success) {
		error(404, "Workshop not found");
	}

	const checkoutSessionId = url.searchParams.get("session_id");
	if (!checkoutSessionId) {
		error(400, "Missing checkout session");
	}

	try {
		await completeExternalWorkshopRegistration(
			workshopIdResult.output,
			checkoutSessionId,
		);
	} catch (err) {
		if (err instanceof ExternalWorkshopRegistrationApiError) {
			error(400, err.message);
		}

		throw err;
	}

	return {
		checkoutSessionId,
	};
};
