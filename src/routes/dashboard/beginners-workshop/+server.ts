import { json } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';

import type { RequestHandler } from './$types';
import { getRolesFromSession, allowedToggleRoles } from '$lib/server/roles';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';

export const POST: RequestHandler = async ({ locals, platform }) => {
	try {
		const canToggleWaitlist =
			getRolesFromSession(locals.session!).intersection(allowedToggleRoles).size > 0;

		if (!canToggleWaitlist) {
			return json({ success: false }, { status: 403 });
		}
		const kysely = getKyselyClient(platform.env.HYPERDRIVE);
		const currentValue = await kysely
			.selectFrom('settings')
			.select('value')
			.where('key', '=', 'waitlist_open')
			.executeTakeFirstOrThrow();

		const newValue = currentValue.value === 'true' ? 'false' : 'true';

		await executeWithRLS(
			{
				claims: locals.session!
			},
			async (trx) => {
				await trx
					.updateTable('settings')
					.set({ value: newValue })
					.where('key', '=', 'waitlist_open')
					.execute();
			}
		);

		return json({ success: true });
	} catch (error) {
		Sentry.captureMessage(`Error toggling waitlist: ${error}}`, 'error');
		return json({ success: false, error: 'Internal server error' }, { status: 500 });
	}
};
