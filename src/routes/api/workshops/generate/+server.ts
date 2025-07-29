import * as v from 'valibot';
import type { RequestHandler } from './$types';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { json } from '@sveltejs/kit';
import { generateWorkshopData, coerceToCreateWorkshopSchema } from '$lib/server/workshop-generator';

export const POST: RequestHandler = async ({ request, locals }) => {
	await authorize(locals, WORKSHOP_ROLES);
	const body = await request.json();
	const output = v.safeParse(
		v.object({
			prompt: v.pipe(v.string(), v.nonEmpty())
		}),
		body
	);

	if (!output.success) {
		return json(
			{
				success: false,
				error: 'No prompt sent'
			},
			{
				status: 400
			}
		);
	}
	try {
		const result = await generateWorkshopData(output.output.prompt, request.signal);
		// Coerce the generated data to the correct format for the form
		const coerced = coerceToCreateWorkshopSchema(result.object);

		if (!coerced.success) {
			return json(
				{
					success: false,
					error: 'Generated data is invalid'
				},
				{ status: 400 }
			);
		}

		return json({
			success: true,
			data: coerced.output
		});
	} catch {
		return json(
			{
				success: false,
				error: 'Failed to generate workshop data'
			},
			{ status: 500 }
		);
	}
};
