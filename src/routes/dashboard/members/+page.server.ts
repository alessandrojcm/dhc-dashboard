import * as Sentry from '@sentry/sveltekit';
import type { Session } from '@supabase/supabase-js';
import { fail, message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { bulkInviteSchema } from '$lib/schemas/adminInvite';
import { invariant } from '$lib/server/invariant';
import { getRolesFromSession, SETTINGS_ROLES } from '$lib/server/roles';
import { createSettingsService } from '$lib/server/services/settings';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { Actions, PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, platform }) => {
	const { session } = await locals.safeGetSession();
	invariant(session === null, 'Unauthorized');
	const roles = getRolesFromSession(session!);
	const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;

	// Use SettingsService to fetch insurance form link
	const settingsService = createSettingsService(platform!, session!);
	const insuranceLinkSetting = await settingsService.findByKey('hema_insurance_form_link');

	return {
		canEditSettings,
		insuranceFormLink: canEditSettings && insuranceLinkSetting ? insuranceLinkSetting.value : ''
	};
};

export const actions: Actions = {
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
