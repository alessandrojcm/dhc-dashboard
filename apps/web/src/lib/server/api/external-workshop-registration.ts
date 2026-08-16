import {
	workshopsCompleteExternalRegistration,
	workshopsCreateExternalCheckoutSession,
	workshopsExternalRegistrationGate,
	type WorkshopExternalCheckoutSessionResponse,
	type WorkshopExternalRegistrationGateResponse,
	type WorkshopRegistrationResponse,
} from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";
import { apiErrorMessage } from "$lib/server/api-error";

export interface ExternalWorkshopRegistrationClient {
	completeRegistration(options: {
		baseUrl: string;
		path: { workshopId: string };
		body: { checkoutSessionId: string };
	}): Promise<ApiResult<WorkshopRegistrationResponse["data"]>>;
	createCheckoutSession(options: {
		baseUrl: string;
		path: { workshopId: string };
		body: { paymentAttemptId: string; returnUrl: string };
	}): Promise<ApiResult<WorkshopExternalCheckoutSessionResponse["data"]>>;
	registrationGate(options: {
		baseUrl: string;
		path: { workshopId: string };
	}): Promise<ApiResult<WorkshopExternalRegistrationGateResponse["data"]>>;
}

interface ApiResult<T> {
	data?: { data: T };
	error?: unknown;
	response?: { status: number };
}

const defaultClient: ExternalWorkshopRegistrationClient = {
	completeRegistration: async (options) =>
		workshopsCompleteExternalRegistration(options),
	createCheckoutSession: async (options) =>
		workshopsCreateExternalCheckoutSession(options),
	registrationGate: async (options) =>
		workshopsExternalRegistrationGate(options),
};

export class ExternalWorkshopRegistrationApiError extends Error {
	constructor(
		message: string,
		public readonly code: string,
	) {
		super(message);
		this.name = "ExternalWorkshopRegistrationApiError";
	}
}

function apiError(cause: unknown, fallback: string) {
	const message = apiErrorMessage(cause, fallback);
	const normalized = message.toLowerCase();

	const code = normalized.includes("full")
		? "WORKSHOP_FULL"
		: normalized.includes("already registered")
			? "ALREADY_REGISTERED"
			: normalized.includes("not found") || normalized.includes("not available")
				? "WORKSHOP_NOT_FOUND"
				: normalized.includes("payment")
					? "PAYMENT_FAILED"
					: "UNKNOWN_ERROR";

	return new ExternalWorkshopRegistrationApiError(message, code);
}

export async function getExternalWorkshopRegistrationGate(
	workshopId: string,
	client: ExternalWorkshopRegistrationClient = defaultClient,
) {
	const response = await client.registrationGate({
		baseUrl: apiBaseUrl(),
		path: { workshopId },
	});

	if (response.error || !response.data) {
		throw apiError(response.error, "Failed to check Workshop availability");
	}

	return response.data
		.data satisfies WorkshopExternalRegistrationGateResponse["data"];
}

export async function createExternalWorkshopCheckoutSession(
	workshopId: string,
	paymentAttemptId: string,
	returnUrl: string,
	client: ExternalWorkshopRegistrationClient = defaultClient,
) {
	const response = await client.createCheckoutSession({
		baseUrl: apiBaseUrl(),
		path: { workshopId },
		body: { paymentAttemptId, returnUrl },
	});

	if (response.error || !response.data) {
		throw apiError(response.error, "Failed to create checkout session");
	}

	return response.data.data;
}

export async function completeExternalWorkshopRegistration(
	workshopId: string,
	checkoutSessionId: string,
	client: ExternalWorkshopRegistrationClient = defaultClient,
) {
	const response = await client.completeRegistration({
		baseUrl: apiBaseUrl(),
		path: { workshopId },
		body: { checkoutSessionId },
	});

	if (response.error || !response.data) {
		throw apiError(response.error, "Failed to complete registration");
	}

	return response.data.data.registration;
}
