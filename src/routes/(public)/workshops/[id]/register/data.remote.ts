import { command, getRequestEvent } from "$app/server";
import { createPublicRegistrationService } from "$lib/server/services/workshops";
import type { ExternalRegistrationError } from "$lib/server/services/workshops";
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
		const { params, platform, url } = getRequestEvent();

		if (input.workshopId !== params.id) {
			return {
				success: false as const,
				error: "Workshop ID mismatch",
				code: "INVALID_INPUT",
			};
		}

		const returnUrl = `${url.origin}/workshops/${input.workshopId}/confirmation?session_id={CHECKOUT_SESSION_ID}`;

		try {
			const service = createPublicRegistrationService(platform!);
			const result = await service.createExternalCheckoutSession({
				workshopId: input.workshopId,
				returnUrl,
			});

			return {
				success: true as const,
				checkoutSessionId: result.checkoutSessionId,
				checkoutClientSecret: result.checkoutClientSecret,
				checkoutUrl: result.checkoutUrl,
			};
		} catch (err) {
			const error = err as ExternalRegistrationError;

			if (error.name === "ExternalRegistrationError") {
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
