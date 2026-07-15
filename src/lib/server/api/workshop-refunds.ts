import {
	workshopsRefundRegistration,
	workshopsRefunds,
	type ApiErrorResponse,
} from "@dhc/api-client";
import type { Session } from "@supabase/supabase-js";
import { apiClientOptions } from "$lib/server/api-client";

function refundApiError(error: unknown, fallback: string) {
	return (error as ApiErrorResponse | undefined)?.errors?.detail ?? fallback;
}

export async function listWorkshopRefunds(
	session: Pick<Session, "access_token">,
	workshopId: string,
) {
	const response = await workshopsRefunds({
		...apiClientOptions(session),
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
	session: Pick<Session, "access_token">,
	{
		workshopId,
		registrationId,
		reason,
	}: { workshopId: string; registrationId: string; reason: string },
) {
	const response = await workshopsRefundRegistration({
		...apiClientOptions(session),
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
