import { invariant } from '$lib/server/invariant';
import { getRolesFromSession, SETTINGS_ROLES } from '$lib/server/roles';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import type { Session } from '@supabase/supabase-js';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import dayjs from 'dayjs';
import * as v from 'valibot';
import type { RequestHandler } from '@sveltejs/kit';
import { PUBLIC_SITE_URL } from '$env/static/public';
import * as Sentry from '@sentry/sveltekit';

const resendInviteSchema = v.object({
	emails: v.pipe(v.array(v.pipe(v.string(), v.email())), v.minLength(1))
});

export const POST: RequestHandler = async ({ request, locals, platform }) => {
	const { session } = await locals.safeGetSession();
	invariant(session === null, 'Unauthorized');
	const roles = getRolesFromSession(session!);
	const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;
	invariant(!canEditSettings, 'Unauthorized', 403);

	const { emails } = v.parse(resendInviteSchema, await request.json());

	const kysely = getKyselyClient(platform.env.HYPERDRIVE);

	await executeWithRLS(
		kysely,
		{
			claims: session as unknown as Session
		},
		async (trx) => {
			for (const email of emails) {
				const { error } = await supabaseServiceClient.auth.admin.inviteUserByEmail(email, {
					redirectTo: `${PUBLIC_SITE_URL}/members/signup/callback`
				});
				if (error) {
					Sentry.captureException(error);
					throw error;
				}
			}

			await trx
				.updateTable('invitations')
				.set({
					status: 'pending',
					expires_at: dayjs().add(1, 'day').toISOString()
				})
				.where('email', 'in', emails)
				.execute();
		}
	);

	return Response.json({ message: 'Invitation link resent' });
};
