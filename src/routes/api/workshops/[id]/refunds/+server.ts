import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { processRefund, getWorkshopRefunds } from '$lib/server/refunds';
import { ProcessRefundSchema } from '$lib/schemas/refunds';
import { safeParse } from 'valibot';
import type { RequestHandler } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';

export const GET: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);
		const refunds = await getWorkshopRefunds(params.id!, session, platform!);
		return json({ success: true, refunds });
	} catch (error) {
		Sentry.captureException(error);
		return json({ success: false, error: (error as Error).message }, { status: 500 });
	}
};

export const POST: RequestHandler = async ({ request, locals, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);

		const body = await request.json();
		const result = safeParse(ProcessRefundSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: 'Invalid data', issues: result.issues },
				{ status: 400 }
			);
		}

		const refund = await processRefund(
			result.output.registration_id,
			result.output.reason,
			session,
			platform!
		);

		return json({ success: true, refund });
	} catch (error) {
		Sentry.captureException(error);
		return json({ success: false, error: (error as Error).message }, { status: 500 });
	}
};
