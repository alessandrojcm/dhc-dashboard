import { command, getRequestEvent } from "$app/server";
import {
	workshopsCancelRegistration,
	workshopsCompleteRegistration,
	workshopsCreateRegistrationPaymentIntent,
	workshopsToggleInterest,
} from "@dhc/api-client";
import { error } from "@sveltejs/kit";
import * as v from "valibot";
import { apiClientOptions } from "$lib/server/api-client";
import { apiErrorMessage } from "$lib/server/api-error";

export const toggleInterest = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const response = await workshopsToggleInterest({
			...apiClientOptions(event.cookies),
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
		customerId: v.optional(v.string()),
	}),
	async (input) => {
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const response = await workshopsCreateRegistrationPaymentIntent({
			...apiClientOptions(event.cookies),
			path: { workshopId: input.workshopId },
			body: input.customerId ? { customerId: input.customerId } : {},
		});

		if (response.error) {
			throw new Error(
				apiErrorMessage(
					response.error,
					"Failed to initialize payment. Please try again later.",
				),
			);
		}

		return { success: true as const, ...response.data.data };
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
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const response = await workshopsCompleteRegistration({
			...apiClientOptions(event.cookies),
			path: { workshopId: input.workshopId },
			body: { paymentIntentId: input.paymentIntentId },
		});

		if (response.error) {
			throw new Error(
				apiErrorMessage(
					response.error,
					"Failed to complete registration. Please try again later.",
				),
			);
		}

		return {
			success: true as const,
			registration: response.data.data.registration,
		};
	},
);

export const cancelRegistration = command(
	v.pipe(v.string(), v.uuid()),
	async (workshopId) => {
		const event = getRequestEvent();
		const { session } = await event.locals.safeGetSession();

		if (!session) {
			error(401, "Authentication required");
		}

		const response = await workshopsCancelRegistration({
			...apiClientOptions(event.cookies),
			path: { workshopId },
		});

		if (response.error) {
			throw new Error(
				apiErrorMessage(
					response.error,
					"Failed to cancel registration. Please try again later.",
				),
			);
		}

		return { success: true as const, ...response.data.data };
	},
);
