import { bulkInviteSchema } from '$lib/schemas/adminInvite';
import settingsSchema from '$lib/schemas/membersSettings';
import { executeWithRLS, getKyselyClient } from '$lib/server/kysely';
import { getRolesFromSession } from '$lib/server/roles';
import { fail, message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { Actions, PageServerLoad } from './$types';
import * as Sentry from '@sentry/sveltekit';

const SETTINGS_ROLES = new Set(['president', 'committee_coordinator', 'admin']);

export const load: PageServerLoad = async ({ locals }) => {
	const roles = getRolesFromSession(locals.session!);
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
		const roles = getRolesFromSession(locals.session!);
		if (roles.intersection(SETTINGS_ROLES).size === 0) {
			return fail(403, { message: 'Unauthorized' });
		}

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
						return message(form, { success: 'Settings updated successfully' });
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
	createBulkInvites: async ({ request, locals, platform }) => {
		const roles = getRolesFromSession(locals.session!);
		if (roles.intersection(SETTINGS_ROLES).size === 0) {
			return fail(403, { message: 'Unauthorized' });
		}

		const form = await superValidate(request, valibot(bulkInviteSchema));
		if (!form.valid) {
			return fail(400, {
				form: {
					...form,
					message: { failure: 'There was an error sending the invites.' }
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
			const { data, error } = await supabaseServiceClient.functions.invoke('bulk_invite_with_subscription', {
				body: payload,
				headers: {
					Authorization: `Bearer ${locals.session?.access_token}`
				}
			});

			if (error) {
				Sentry.captureMessage(`Edge function error: ${JSON.stringify(error)}`, 'error');
				return fail(500, {
					form,
					message: { failure: 'Failed to process invitations. Please try again later.' }
				});
			}

			return message(form, {
				success: 'Invitations are being processed in the background. You will be notified when completed.'
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
