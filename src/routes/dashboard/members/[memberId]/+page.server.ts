import { error, type Actions } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, message, setError, superValidate } from 'sveltekit-superforms';
import signupSchema from '$lib/schemas/membersSignup';
import type { Database } from 'lucide-svelte';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';

export const load: PageServerLoad = async ({ params, locals }) => {
	const memberData = await locals.supabase.rpc('get_member_data', {
		user_uuid: params.memberId
	});
	if (memberData.error) {
		error(404, {
			message: 'Member not found'
		});
	}
	const memberProfile: Database['public']['CompositeTypes']['member_data_type'] = memberData.data!;
	const email = await supabaseServiceClient.auth.admin
		.getUserById(params.memberId)
		.then((u) => u.data?.user?.email ?? '');

	return {
		form: await superValidate(
			{
				firstName: memberProfile.first_name,
				lastName: memberProfile.last_name,
				email,
				phoneNumber: memberProfile.phone_number,
				dateOfBirth: new Date(memberProfile.date_of_birth),
				pronouns: memberProfile.pronouns,
				gender: memberProfile.gender,
				medicalConditions: memberProfile.medical_conditions,
				nextOfKin: memberProfile.next_of_kin_name,
				nextOfKinNumber: memberProfile.next_of_kin_phone,
				weapon: memberProfile.preferred_weapon,
				insuranceFormSubmitted: memberProfile.insurance_form_submitted
			},
			valibot(signupSchema),
			{ errors: false }
		),
		genders: locals.supabase.rpc('get_gender_options').then((r) => r.data ?? []) as Promise<
			string[]
		>,
		weapons: locals.supabase.rpc('get_weapons_options').then((r) => r.data ?? []) as Promise<
			string[]
		>
	};
};

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(signupSchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		const { error } = await event.locals.supabase.rpc('update_member_data', {
			user_uuid: event.params.memberId!,
			p_first_name: form.data.firstName,
			p_last_name: form.data.lastName,
			p_phone_number: form.data.phoneNumber,
			p_date_of_birth: form.data.dateOfBirth.toISOString(),
			p_pronouns: form.data.pronouns,
			p_gender: form.data.gender as Database['public']['Enums']['gender'],
			p_medical_conditions: form.data.medicalConditions,
			p_next_of_kin_name: form.data.nextOfKin,
			p_next_of_kin_phone: form.data.nextOfKinNumber,
			p_preferred_weapon: form.data.weapon as Database['public']['Enums']['preferred_weapon'],
			p_insurance_form_submitted: form.data.insuranceFormSubmitted
		});
		if (error) {
			return setError(form, 'pronouns', 'There was an error updating your profile.');
		}
		return message(form, { success: 'Your profile has been updated!' });
	}
};
