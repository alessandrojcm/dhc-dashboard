import {
	workshopsRefundRegistration,
	workshopsRefunds,
	type WorkshopRefundResponse,
	type WorkshopRefundsResponse,
} from "@dhc/api-client";
import { apiClientOptions, type Cookies } from "$lib/server/api-client";
import { apiErrorMessage } from "$lib/server/api-error";

export interface WorkshopRefundClient {
	refundRegistration(
		options: RefundRegistrationOptions,
	): Promise<ApiResult<WorkshopRefundResponse["data"]>>;
	listRefunds(
		options: ListRefundsOptions,
	): Promise<ApiResult<WorkshopRefundsResponse["data"]>>;
}

interface ApiResult<T> {
	data?: { data: T };
	error?: unknown;
}

interface ListRefundsOptions {
	baseUrl: string;
	credentials: "include";
	headers: Record<string, string>;
	path: { workshopId: string };
}

interface RefundRegistrationOptions extends ListRefundsOptions {
	path: { workshopId: string; registrationId: string };
	body: { reason: string };
}

const defaultClient: WorkshopRefundClient = {
	refundRegistration: async (options) => workshopsRefundRegistration(options),
	listRefunds: async (options) => workshopsRefunds(options),
};

/**
 * ALE-164: the dashboard authenticates through the Phoenix `_dhc_session`
 * cookie. These helpers take a `Cookies` (SvelteKit request cookies) and
 * forward it to Phoenix via `apiClientOptions`, instead of the prior
 * Supabase `access_token`.
 */
export async function listWorkshopRefunds(
	cookies: Cookies,
	workshopId: string,
	client: WorkshopRefundClient = defaultClient,
) {
	const response = await client.listRefunds({
		...apiClientOptions(cookies),
		path: { workshopId },
	});

	if (response.error || !response.data) {
		throw new Error(
			apiErrorMessage(response.error, "Failed to load Workshop refunds."),
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
	client: WorkshopRefundClient = defaultClient,
) {
	const response = await client.refundRegistration({
		...apiClientOptions(cookies),
		path: { workshopId, registrationId },
		body: { reason },
	});

	if (response.error || !response.data) {
		throw new Error(
			apiErrorMessage(response.error, "Failed to process Workshop refund."),
		);
	}

	return response.data.data.refund;
}
