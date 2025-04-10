import { adminInviteSchema, bulkInviteSchema } from '$lib/schemas/adminInvite';
import settingsSchema from '$lib/schemas/membersSettings';
import { executeWithRLS } from '$lib/server/kysely';
import { createInvitation } from '$lib/server/kyselyRPCFunctions';
import { getRolesFromSession } from '$lib/server/roles';
import type { AuthError } from '@supabase/supabase-js';
import dayjs from 'dayjs';
import { fail, message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { Actions, PageServerLoad } from './$types';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';

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
	updateSettings: async ({ request, locals }) => {
		const roles = getRolesFromSession(locals.session!);
		if (roles.intersection(SETTINGS_ROLES).size === 0) {
			return fail(403, { message: 'Unauthorized' });
		}

		const form = await superValidate(request, valibot(settingsSchema));
		if (!form.valid) {
			return fail(400, { form });
		}

		return executeWithRLS(
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
						console.error('Error updating settings:', error);
						return fail(500, {
							form,
							message: { failure: 'Failed to update settings' }
						});
					});
			}
		);
	},
	createBulkInvites: async ({ request, locals }) => {
		const roles = getRolesFromSession(locals.session!);
		if (roles.intersection(SETTINGS_ROLES).size === 0) {
			return fail(403, { message: 'Unauthorized' });
		}

		const form = await superValidate(request, valibot(bulkInviteSchema));
		if (!form.valid) {
			return fail(400, {
				form: {
					...form,
					message: { failure: 'There was an error seding the invites.' }
				}
			});
		}
		const invites = form.data.invites;

		try {
			const results: Array<{ email: string; success: boolean; error?: any }> = [];

			// Process invites in a transaction
			await executeWithRLS(
				{
					claims: locals.session!
				},
				async (trx) => {
					for (const invite of invites) {
						const { firstName, lastName, email, phoneNumber, dateOfBirth, expirationDays } = invite;

						// Calculate expiration date based on the invite's expirationDays or default to 7 days
						const expiresAt = dayjs()
							.add(expirationDays || 7, 'day')
							.toDate();

						// Create metadata with user details
						const metadata = {
							firstName,
							lastName,
							phoneNumber,
							dateOfBirth: dateOfBirth.toISOString()
						};

						try {
							// Also invite the user via Supabase Admin SDK
							const result = await supabaseServiceClient.auth.admin.inviteUserByEmail(email, {
								data: {
									first_name: firstName,
									last_name: lastName
								}
							});

							if (result.error) {
								throw result.error;
							}
							// Create invitation using the kysely function
							await createInvitation(
								{
									userId: result.data.user?.id!,
									email,
									invitationType: 'admin',
									expiresAt,
									metadata,
									firstName,
									lastName,
									dateOfBirth: dateOfBirth.toISOString(),
									phoneNumber
								},
								trx
							);

							results.push({ email, success: true });
						} catch (error) {
							console.error(`Error inviting ${email}:`, error);
							results.push({ email, success: false, error: error as AuthError });
						}
					}
				}
			);

			const successCount = results.filter((r) => r.success).length;
			const failureCount = results.length - successCount;

			if (failureCount === 0) {
				return message(form, {
					success: `Successfully sent ${successCount} invitation${successCount !== 1 ? 's' : ''}`
				});
			} else {
				return message(form, {
					warning: `Sent ${successCount} invitation${successCount !== 1 ? 's' : ''}, but ${failureCount} failed`
				});
			}
		} catch (error) {
			console.error('Error creating bulk invitations:', error);
			return fail(500, {
				form,
				message: { failure: 'Failed to create invitations' }
			});
		}
	}
};
