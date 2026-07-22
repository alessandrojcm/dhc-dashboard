import {
	workshopsCompleteExternalRegistration,
	workshopsCreateExternalCheckoutSession,
	workshopsExternalRegistrationGate,
	type ApiErrorResponse,
	type WorkshopExternalRegistrationGateResponse,
} from "@dhc/api-client";
import { apiBaseUrl } from "$lib/server/api-client";

export class ExternalWorkshopRegistrationApiError extends Error {
	constructor(
		message: string,
		public readonly code: string,
	) {
		super(message);
		this.name = "ExternalWorkshopRegistrationApiError";
	}
}

function apiError(error: unknown, fallback: string) {
	const message =
		(error as ApiErrorResponse | undefined)?.errors?.detail ?? fallback;
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

export async function getExternalWorkshopRegistrationGate(workshopId: string) {
	const response = await workshopsExternalRegistrationGate({
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
	returnUrl: string,
) {
	const response = await workshopsCreateExternalCheckoutSession({
		baseUrl: apiBaseUrl(),
		path: { workshopId },
		body: { returnUrl },
	});

	if (response.error || !response.data) {
		throw apiError(response.error, "Failed to create checkout session");
	}

	return response.data.data;
}

export async function completeExternalWorkshopRegistration(
	workshopId: string,
	checkoutSessionId: string,
) {
	const response = await workshopsCompleteExternalRegistration({
		baseUrl: apiBaseUrl(),
		path: { workshopId },
		body: { checkoutSessionId },
	});

	if (response.error || !response.data) {
		throw apiError(response.error, "Failed to complete registration");
	}

	return response.data.data.registration;
}
