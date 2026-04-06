import { command, getRequestEvent } from "$app/server";
import { createPublicRegistrationService } from "$lib/server/services/workshops";
import type { ExternalRegistrationError } from "$lib/server/services/workshops";
import {
	CreateExternalPaymentIntentSchema,
	CompleteExternalRegistrationSchema,
} from "$lib/schemas/workshop-registration";

/**
 * Create a payment intent for external (non-member) workshop registration.
 *
 * This command:
 * - Validates input with Valibot
 * - Ensures workshopId in input matches route params
 * - Calls public registration service to create payment intent
 * - Returns success with clientSecret, paymentIntentId, amount, currency
 * - Returns error with code on failure
 *
 * Stage 3C contract compliance:
 * - Success: { success: true, clientSecret, paymentIntentId, amount, currency }
 * - Error: { success: false, error: string, code?: string }
 */
export const createExternalPaymentIntent = command(
	CreateExternalPaymentIntentSchema,
	async (input) => {
		const { params, platform } = getRequestEvent();

		// Enforce route/body match
		if (input.workshopId !== params.id) {
			return {
				success: false,
				error: "Workshop ID mismatch",
				code: "INVALID_INPUT",
			};
		}

		try {
			const service = createPublicRegistrationService(platform!);
			const result = await service.createExternalPaymentIntent(input);

			return {
				success: true,
				...result,
			};
		} catch (err) {
			const error = err as ExternalRegistrationError;

			// Map domain errors to response format
			if (error.name === "ExternalRegistrationError") {
				return {
					success: false,
					error: error.message,
					code: error.code,
				};
			}

			// Generic error fallback
			return {
				success: false,
				error: "Failed to create payment intent",
				code: "UNKNOWN_ERROR",
			};
		}
	},
);

/**
 * Complete external workshop registration after payment confirmation.
 *
 * This command:
 * - Validates input with Valibot
 * - Ensures workshopId in input matches route params
 * - Calls public registration service to complete registration
 * - Returns success with redirectTo path
 * - Returns error with code on failure
 *
 * Stage 3D contract compliance:
 * - Success: { success: true, redirectTo: "/workshops/[id]/confirmation" }
 * - Error: { success: false, error: string, code?: string }
 */
export const completeExternalRegistration = command(
	CompleteExternalRegistrationSchema,
	async (input) => {
		const { params, platform } = getRequestEvent();

		// Enforce route/body match
		if (input.workshopId !== params.id) {
			return {
				success: false,
				error: "Workshop ID mismatch",
				code: "INVALID_INPUT",
			};
		}

		try {
			const service = createPublicRegistrationService(platform!);
			await service.completeExternalRegistration(input);

			return {
				success: true,
				redirectTo: `/workshops/${input.workshopId}/confirmation`,
			};
		} catch (err) {
			const error = err as ExternalRegistrationError;

			// Map domain errors to response format
			if (error.name === "ExternalRegistrationError") {
				return {
					success: false,
					error: error.message,
					code: error.code,
				};
			}

			// Generic error fallback
			return {
				success: false,
				error: "Failed to complete registration",
				code: "UNKNOWN_ERROR",
			};
		}
	},
);
