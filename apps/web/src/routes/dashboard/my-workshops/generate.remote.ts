import { command, getRequestEvent } from "$app/server";
import * as v from "valibot";
import { authorize } from "#lib/server/auth.js";
import {
	generateWorkshopData,
	coerceToCreateWorkshopSchema,
} from "#lib/server/workshop-generator.js";

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
		await authorize(locals, "workshops.manage");

		try {
			const result = await generateWorkshopData(prompt, request.signal);
			// Check the draft can become a workshop, but hand back the draft
			// itself: the create page reads it from its URL and converts it
			// once, on the Dublin clock, with the same function.
			if (!coerceToCreateWorkshopSchema(result.object).success) {
				return { success: false as const, error: "Generated data is invalid" };
			}

			return { success: true as const, data: result.object };
		} catch {
			return {
				success: false as const,
				error: "Failed to generate workshop data",
			};
		}
	},
);
