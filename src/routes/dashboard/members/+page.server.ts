import type { PageServerLoad, Actions } from './$types';
import { getRolesFromSession } from '$lib/server/getRolesFromSession';
import { superValidate, fail, message } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import settingsSchema from '$lib/schemas/membersSettings';

const SETTINGS_ROLES = new Set(['president', 'committee_coordinator', 'admin']);

export const load: PageServerLoad = async ({ locals }) => {
	const roles = getRolesFromSession(locals.session!);
	const canEditSettings = roles.intersection(SETTINGS_ROLES).size > 0;
	if (!canEditSettings) {
		return {
			canEditSettings
		};
	}
	const { data } = await locals.supabase
		.from('settings')
		.select('value')
		.eq('key', 'hema_insurance_form_link')
		.single();

	return {
		canEditSettings,
		form: superValidate(
			{
				insuranceFormLink: data ? data.value : ''
			},
			valibot(settingsSchema),
			{ errors: false }
		)
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

		const { error } = await locals.supabase
			.from('settings')
			.update({ value: form.data.insuranceFormLink })
			.eq('key', 'hema_insurance_form_link');

		if (error) {
			fail(500, {
				form,
				message: { failure: 'Failed to update settings' }
			});
		}

		return message(form, { success: 'Settings updated successfully' });
	}
};
