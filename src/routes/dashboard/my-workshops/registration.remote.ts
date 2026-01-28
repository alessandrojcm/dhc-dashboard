import { command, getRequestEvent } from "$app/server";
import { error } from "@sveltejs/kit";
import * as v from "valibot";
import { createRegistrationService } from "$lib/server/services/workshops";

export const toggleInterest = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const { locals, platform } = getRequestEvent();
		const { session } = await locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const service = createRegistrationService(platform!, session);
		const result = await service.toggleInterest(workshopId);
		return { success: true as const, ...result };
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
