import {
	workshopsRefundRegistration,
	workshopsRefunds,
	type ApiErrorResponse,
} from "@dhc/api-client";
import { apiClientOptions, type Cookies } from "$lib/server/api-client";

function refundApiError(error: unknown, fallback: string) {
	return (error as ApiErrorResponse | undefined)?.errors?.detail ?? fallback;
}

/**
 * ALE-164: the dashboard authenticates through the Phoenix `_dhc_session`
 * cookie. These helpers take a `Cookies` (SvelteKit request cookies) and
 * forward it to Phoenix via `apiClientOptions`, instead of the prior
 * Supabase `access_token`.
 */
export async function listWorkshopRefunds(
	cookies: Cookies,
	workshopId: string,
) {
	const response = await workshopsRefunds({
		...apiClientOptions(cookies),
		path: { workshopId },
	});

	if (response.error) {
		throw new Error(
			refundApiError(response.error, "Failed to load Workshop refunds."),
		);
	}

	return response.data.data.refunds;
}

export async function submitWorkshopRefund(
	cookies: Cookies,
	{
		workshopId,
		registrationId,
		reason,
	}: { workshopId: string; registrationId: string; reason: string },
) {
	const response = await workshopsRefundRegistration({
		...apiClientOptions(cookies),
		path: { workshopId, registrationId },
		body: { reason },
	});

	if (response.error) {
		throw new Error(
			refundApiError(response.error, "Failed to process Workshop refund."),
		);
	}

	return response.data.data.refund;
}
