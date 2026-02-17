import type { RequestHandler } from '@sveltejs/kit';
import dayjs from 'dayjs';
import * as v from 'valibot';
import { PUBLIC_SITE_URL } from '$env/static/public';
import { invariant } from '$lib/server/invariant';
import { getKyselyClient, sql } from '$lib/server/kysely';
import { getRolesFromSession, SETTINGS_ROLES } from '$lib/server/roles';

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

	const kysely = getKyselyClient(platform?.env.HYPERDRIVE);
	// We have gotten the current user with SafeGetSession, so we know there are admins
	// we do not execute with RLS here as pgmq has no RLS enabled
	await kysely.transaction().execute(async (trx) => {
		const payload = await trx
			.selectFrom('invitations')
			.select(['email', 'invitations.id'])
			.leftJoin('user_profiles', 'user_profiles.supabase_user_id', 'invitations.user_id')
			.select(['first_name', 'last_name', 'date_of_birth'])
			.where('email', 'in', emails)
			.execute()
			.then((inviteData) => {
				return inviteData.map((i) => {
					const invitationLink = new URL(
						`/members/signup/${i.id}`,
						PUBLIC_SITE_URL ?? 'http://localhost:5173'
					);
					invitationLink.searchParams.set(
						'dateOfBirth',
						dayjs(i.date_of_birth).format('YYYY-MM-DD')
					);
					invitationLink.searchParams.set('email', i.email);
					return {
						transactionalId: 'inviteMember',
						email: i.email,
						dataVariables: {
							firstName: i.first_name,
							lastName: i.last_name,
							invitationLink: invitationLink.toString()
						}
					};
				});
			});

		await sql`
			select *
			from pgmq.send_batch(
				'email_queue',
				${payload}::jsonb[]
					 )
		`.execute(trx);

		await trx
			.updateTable('invitations')
			.set({
				status: 'pending',
				expires_at: dayjs().add(1, 'day').toISOString()
			})
			.where('email', 'in', emails)
			.execute();
	});

	return Response.json({ message: 'Invitation link resent' });
};
