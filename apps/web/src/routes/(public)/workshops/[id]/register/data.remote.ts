import { command, getRequestEvent } from "$app/server";
import {
	createExternalWorkshopCheckoutSession,
	ExternalWorkshopRegistrationApiError,
} from "$lib/server/api/external-workshop-registration";
import { CreateExternalCheckoutSessionCommandSchema } from "$lib/schemas/workshop-registration";

/**
 * Creates a Stripe Checkout Session for external registration.
 *
 * Success: { success: true, checkoutSessionId: string, checkoutClientSecret: string, checkoutUrl: string | null }
 * Error:   { success: false, error: string, code?: string }
 */
export const createExternalCheckoutSession = command(
	CreateExternalCheckoutSessionCommandSchema,
	async (input) => {
		const { params, url } = getRequestEvent();

		if (input.workshopId !== params.id) {
			return {
				success: false as const,
				error: "Workshop ID mismatch",
				code: "INVALID_INPUT",
			};
		}

		const returnUrl = `${url.origin}/workshops/${input.workshopId}/confirmation?session_id={CHECKOUT_SESSION_ID}`;

		try {
			const result = await createExternalWorkshopCheckoutSession(
				input.workshopId,
				returnUrl,
			);

			return {
				success: true as const,
				checkoutSessionId: result.checkoutSessionId,
				checkoutClientSecret: result.checkoutClientSecret,
				checkoutUrl: result.checkoutUrl,
			};
		} catch (err) {
			const error = err as ExternalWorkshopRegistrationApiError;

			if (error.name === "ExternalWorkshopRegistrationApiError") {
				return {
					success: false as const,
					error: error.message,
					code: error.code,
				};
			}

			return {
				success: false as const,
				error: "Failed to create checkout session",
				code: "UNKNOWN_ERROR",
			};
		}
	},
);
