import { bulkInviteSchema } from '$lib/schemas/adminInvite';
import settingsSchema from '$lib/schemas/membersSettings';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import { getRolesFromSession, SETTINGS_ROLES } from '$lib/server/roles';
import { fail, message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { Actions, PageServerLoad } from './$types';
import * as Sentry from '@sentry/sveltekit';
import { invariant } from '$lib/server/invariant';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { Session } from '@supabase/supabase-js';

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
		const kysely = getKyselyClient(platform!.env.HYPERDRIVE);
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
	}
};
