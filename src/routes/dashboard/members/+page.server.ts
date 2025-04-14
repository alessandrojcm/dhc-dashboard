import { adminInviteSchema, bulkInviteSchema } from '$lib/schemas/adminInvite';
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
	const inviteForm = await superValidate(
		{
			dateOfBirth: new Date('2000-01-01'),
			expirationDays: 7
		},
		valibot(adminInviteSchema),
		{ errors: false }
	);
	const bulkInviteForm = await superValidate({ invites: [] }, valibot(bulkInviteSchema), {
		errors: false
	});
	if (!canEditSettings) {
		return {
			canEditSettings,
			form,
			inviteForm,
			bulkInviteForm
		};
	}

	return {
		canEditSettings,
		form,
		inviteForm,
		bulkInviteForm
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

			// Call the Edge Function asynchronously
			const edgeFunctionUrl = platform?.env?.EDGE_FUNCTION_URL || 'http://localhost:54321/functions/v1';
			const response = await fetch(`${edgeFunctionUrl}/bulk_invite_with_subscription`, {
				method: 'POST',
				headers: { 
					'Content-Type': 'application/json',
					'Authorization': `Bearer ${locals.session?.access_token}`
				},
				body: JSON.stringify(payload)
			});

			if (!response.ok) {
				const errorData = await response.json();
				Sentry.captureMessage(`Edge function error: ${JSON.stringify(errorData)}`, 'error');
				return fail(response.status, {
					form,
					message: { failure: 'Failed to process invitations. Please try again later.' }
				});
			}

			const data = await response.json() as { results: Array<{ email: string; success: boolean; error?: string }> };
			const results = data.results || [];
			const successCount = results.filter(r => r.success).length;
			const failureCount = results.length - successCount;

			if (failureCount === 0) {
				return message(form, {
					success: `Successfully sent ${successCount} invitation${successCount !== 1 ? 's' : ''}`
				});
			} else if (successCount > 0) {
				return message(form, {
					warning: `Sent ${successCount} invitation${successCount !== 1 ? 's' : ''}, but ${failureCount} failed`
				});
			} else {
				return fail(500, {
					form,
					message: { failure: 'Failed to create invitations' }
				});
			}
		} catch (error) {
			Sentry.captureMessage(`Error creating bulk invitations: ${error}`, 'error');
			return fail(500, {
				form,
				message: { failure: 'Failed to create invitations' }
			});
		}
	}
};
