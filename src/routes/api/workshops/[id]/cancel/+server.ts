import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { cancelWorkshop } from '$lib/server/workshops';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';

export const POST: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const workshop = await cancelWorkshop(params.id!, session, platform!);

		return json({ success: true, workshop });
	} catch (error) {
		Sentry.captureException(error);
		console.error('Cancel workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
