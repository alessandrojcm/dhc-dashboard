import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { valibot } from 'sveltekit-superforms/adapters';
import { superValidate } from 'sveltekit-superforms';
import signupSchema from '$lib/schemas/membersSignup';
import type { Database } from 'lucide-svelte';

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
	return {
		form: await superValidate(
			{
				firstName: memberProfile.first_name,
                lastName: memberProfile.last_name,
                email: locals.user?.email,
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
