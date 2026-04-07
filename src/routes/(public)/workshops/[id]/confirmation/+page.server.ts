import { error } from "@sveltejs/kit";
import * as v from "valibot";
import { createPublicRegistrationService } from "$lib/server/services/workshops";
import type { ExternalRegistrationError } from "$lib/server/services/workshops";

export const load = async ({
	params,
	platform,
	url,
}: {
	params: { id: string };
	platform: App.Platform | undefined;
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

	const service = createPublicRegistrationService(platform!);

	try {
		await service.completeExternalRegistrationFromCheckoutSession({
			workshopId: workshopIdResult.output,
			checkoutSessionId,
		});
	} catch (err) {
		const domainError = err as ExternalRegistrationError;
		if (domainError.name === "ExternalRegistrationError") {
			error(400, domainError.message);
		}

		throw err;
	}

	return {
		checkoutSessionId,
	};
};
