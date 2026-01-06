import { command, getRequestEvent } from "$app/server";
import * as v from "valibot";
import { authorize } from "$lib/server/auth";
import { WORKSHOP_ROLES } from "$lib/server/roles";
import {
	generateWorkshopData,
	coerceToCreateWorkshopSchema,
} from "$lib/server/workshop-generator";

/**
 * Generate workshop data from a natural language prompt using AI.
 * Requires workshop coordinator role or higher.
 */
export const generateWorkshop = command(
	v.object({
		prompt: v.pipe(v.string(), v.nonEmpty(), v.maxLength(1000)),
	}),
	async ({ prompt }) => {
		const { locals, request } = getRequestEvent();
		await authorize(locals, WORKSHOP_ROLES);

		try {
			const result = await generateWorkshopData(prompt, request.signal);
			const coerced = coerceToCreateWorkshopSchema(result.object);

			if (!coerced.success) {
				return { success: false as const, error: "Generated data is invalid" };
			}

			return { success: true as const, data: coerced.output };
		} catch {
			return {
				success: false as const,
				error: "Failed to generate workshop data",
			};
		}
	},
);
