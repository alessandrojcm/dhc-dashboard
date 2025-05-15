import type { RequestHandler } from '@sveltejs/kit';
import * as v from 'valibot';
import { getKyselyClient } from '$lib/server/kysely';
import { inviteValidationSchema } from '$lib/schemas/inviteValidationSchema';

export const POST: RequestHandler = async ({ request, params, platform }) => {
	const invitationId = v.safeParse(v.pipe(v.string(), v.nonEmpty(), v.uuid()), params.invitationId);
	if (!invitationId.success) {
		return new Response(null, { status: 404 });
	}

	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const invitationPayload = v.safeParse(inviteValidationSchema, await request.json());

	if (!invitationPayload.success) {
		return new Response(null, { status: 400 });
	}
	return kysely
		.selectFrom('invitations')
		.select(['invitations.id'])
		.where('invitations.id', '=', invitationId.output)
		.where('email', '=', invitationPayload.output.email)
		.where('status', '=', 'pending')
		.leftJoin('user_profiles', 'user_profiles.supabase_user_id', 'invitations.user_id')
		.where('date_of_birth', '=', invitationPayload.output.dateOfBirth)
		.executeTakeFirst()
		.then((result) => {
			if (!result?.id) {
				return new Response(null, { status: 404 });
			}
			return new Response(null, { status: 200 });
		});
};
