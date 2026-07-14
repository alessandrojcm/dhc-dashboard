import { command, getRequestEvent } from "$app/server";
import { workshopsToggleInterest, type ApiErrorResponse } from "@dhc/api-client";
import { error } from "@sveltejs/kit";
import * as v from "valibot";
import { apiClientOptions } from "$lib/server/api-client";
import { createRegistrationService } from "$lib/server/services/workshops";

function apiErrorMessage(error: unknown, fallback: string) {
	return (error as ApiErrorResponse | undefined)?.errors?.detail ?? fallback;
}

export const toggleInterest = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const response = await workshopsToggleInterest({
			...apiClientOptions(session),
			path: { workshopId },
		});

		if (response.error) {
			throw new Error(
				apiErrorMessage(
					response.error,
					"Failed to manage interest. Please try again later.",
				),
			);
		}

		return { success: true as const, ...response.data.data };
	},
);

export const createPaymentIntent = command(
	v.object({
		workshopId: v.pipe(v.string(), v.uuid()),
		amount: v.pipe(v.number(), v.minValue(1, "Amount must be positive")),
		currency: v.optional(v.string(), "eur"),
		customerId: v.optional(v.string()),
	}),
	async (input) => {
		const { locals, platform } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const service = createRegistrationService(platform!, session);
		const result = await service.createPaymentIntent(input);
		return { success: true as const, ...result };
	},
);

export const completeRegistration = command(
	v.object({
		workshopId: v.pipe(v.string(), v.uuid()),
		paymentIntentId: v.pipe(
			v.string(),
			v.nonEmpty("Payment intent ID required"),
		),
	}),
	async (input) => {
		const { locals, platform } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const service = createRegistrationService(platform!, session);
		const registration = await service.completeRegistration(input);
		return { success: true as const, registration };
	},
);

export const cancelRegistration = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals, platform } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const service = createRegistrationService(platform!, session);
		const result = await service.cancelRegistration(workshopId);
		return { success: true as const, ...result };
	},
);
