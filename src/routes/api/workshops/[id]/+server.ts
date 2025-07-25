import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { deleteWorkshop } from '$lib/server/workshops';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';

export const DELETE: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		await deleteWorkshop(params.id!, session, platform!);

		return json({ success: true });
	} catch (error) {
		Sentry.captureException(error);
		console.error('Delete workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
