import { bulkInviteSchema } from '$lib/schemas/adminInvite';
import settingsSchema from '$lib/schemas/membersSettings';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import { getRolesFromSession } from '$lib/server/roles';
import { fail, message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import * as v from 'valibot';
import type { Actions, PageServerLoad } from './$types';
import * as Sentry from '@sentry/sveltekit';
import { invariant } from '$lib/server/invariant';
import { PUBLIC_SITE_URL } from '$env/static/public';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { Session } from '@supabase/supabase-js';
import dayjs from 'dayjs';

const SETTINGS_ROLES = new Set(['president', 'committee_coordinator', 'admin']);

const resendInviteSchema = v.object({
	emails: v.pipe(v.array(v.pipe(v.string(), v.email())), v.minLength(1))
});

export const load: PageServerLoad = async ({ locals }) => {
	const { session } = await locals.safeGetSession();
	invariant(session === null, 'Unauthorized');
	const roles = getRolesFromSession(session!);
	const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;

	const { data } = await locals.supabase
		.from('settings')
		.select('value')
		.eq('key', 'hema_insurance_form_link')
		.single();
	const form = await superValidate(
		{
			insuranceFormLink: canEditSettings && data ? data.value : ''
		},
		valibot(settingsSchema),
		{ errors: false }
	);
	if (!canEditSettings) {
		return {
			canEditSettings,
			form
		};
	}

	return {
		canEditSettings,
		form
	};
};

export const actions: Actions = {
	updateSettings: async ({ request, locals, platform }) => {
		const { session } = await locals.safeGetSession();
		invariant(session === null, 'Unauthorized');
		const roles = getRolesFromSession(session!);
		invariant(roles.intersection(SETTINGS_ROLES).size > 0, 'Unauthorized', 403);

		const form = await superValidate(request, valibot(settingsSchema));
		if (!form.valid) {
			return fail(400, { form });
		}
		const kysely = getKyselyClient(platform.env.HYPERDRIVE);
		return executeWithRLS(
			kysely,
			{
				claims: locals.session!
			},
			async (trx) => {
				return trx
					.updateTable('settings')
					.set({ value: form.data.insuranceFormLink })
					.where('key', '=', 'hema_insurance_form_link')
					.execute()
					.then(() => {
						return message(form, {
							success: 'Settings updated successfully'
						});
					})
					.catch((error) => {
						Sentry.captureMessage(`Error updating settings: ${error}}`, 'error');
						return fail(500, {
							form,
							message: { failure: 'Failed to update settings' }
						});
					});
			}
		);
	},
	createBulkInvites: async ({ request, locals }) => {
		const { session } = await locals.safeGetSession();
		invariant(session === null, 'Unauthorized');
		const roles = getRolesFromSession(session!);
		invariant(roles.intersection(SETTINGS_ROLES).size === 0, 'Unauthorized', 403);

		const form = await superValidate(request, valibot(bulkInviteSchema));
		if (!form.valid) {
			return fail(400, {
				form: {
					...form,
					message: {
						failure: 'There was an error sending the invites.'
					}
				}
			});
		}

		try {
			// Prepare the payload for the Edge Function
			const payload = {
				invites: form.data.invites,
				session: locals.session
			};

			// Call the Edge Function asynchronously using the Supabase SDK
			const { error } = await supabaseServiceClient.functions.invoke(
				'bulk_invite_with_subscription',
				{
					body: payload,
					headers: {
						Authorization: `Bearer ${(session as unknown as Session)?.access_token}`
					}
				}
			);

			if (error) {
				Sentry.captureMessage(`Edge function error: ${JSON.stringify(error)}`, 'error');
				return fail(500, {
					form,
					message: {
						failure: 'Failed to process invitations. Please try again later.'
					}
				});
			}

			return message(form, {
				success:
					'Invitations are being processed in the background. You will be notified when completed.'
			});
		} catch (error) {
			Sentry.captureMessage(`Error creating bulk invitations: ${error}`, 'error');
			return fail(500, {
				form,
				message: { failure: 'Failed to create invitations' }
			});
		}
	},
	resendInvitationLink: async ({ request, locals, platform }) => {
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
					await supabaseServiceClient.auth.admin.generateLink({
						email,
						type: 'magiclink',
						options: {
							redirectTo: `${PUBLIC_SITE_URL}/members/signup/callback`
						}
					});
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

		return { success: true };
	}
};
