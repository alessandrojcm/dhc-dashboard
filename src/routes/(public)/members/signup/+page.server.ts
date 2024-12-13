import { memberSignupSchema } from '$lib/schemas/membersSignup';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient.js';
import { error, fail, redirect } from '@sveltejs/kit';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import { setError, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { Actions, PageServerLoad } from './$types';
import type { Database } from '$database';

function invariant(condition: unknown, message: string): asserts condition {
	if (condition) {
		error(404, { message });
	}
}

// need to normalize medical_conditions
export const load: PageServerLoad = async ({ url }) => {
	try {
		const accessToken = url.searchParams.get('access_token');
		invariant(accessToken === null, `${url.pathname}?error_description=missing_access_token`);
		const tokenClaim = jwtDecode(accessToken!);
		invariant(
			dayjs.unix(tokenClaim.exp!).isBefore(dayjs()),
			`${url.pathname}?error_description=expired_access_token`
		);

		const userData = await supabaseServiceClient.auth.admin.getUserById(tokenClaim.sub!);
		invariant(userData.error || !userData.data?.user, 'This invite is not valid');

		const waitlistedMemberData = await supabaseServiceClient
			.rpc('get_membership_info', {
				uid: userData.data.user!.id
			})
			.single();
		// cannot used the invariant otherwhise typescript will
		// cast data to null
		if (waitlistedMemberData.error !== null) {
			error(404, {
				message: 'Waitlist entry not found'
			});
		}
		const { data } = waitlistedMemberData as unknown as {
			data: Database['public']['CompositeTypes']['member_data_type'];
		};

		return {
			form: await superValidate({}, valibot(memberSignupSchema), { errors: false }),
			userData: {
				firstName: data?.first_name,
				lastName: data?.last_name,
				email: userData.data.user!.email,
				dateOfBirth: new Date(data?.date_of_birth),
				phoneNumber: data?.phone_number,
				pronouns: data?.pronouns,
				gender: data?.gender,
				medicalConditions: data?.medical_conditions
			}
		};
	} catch (err) {
		error(404, {
			message: 'Waitlist entry not found'
		});
	}
};

export const actions: Actions = {
	default: async (event) => {
		const accessToken = event.url.searchParams.get('access_token');
		invariant(accessToken === null, `${event.url.pathname}?error_description=missing_access_token`);
		const tokenClaim = jwtDecode(accessToken!);
		invariant(
			dayjs.unix(tokenClaim.exp!).isBefore(dayjs()),
			`${event.url.pathname}?error_description=expired_access_token`
		);

		const form = await superValidate(event, valibot(memberSignupSchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		//TODO: send email with thank you and encourage to set direct debit
		const { error } = await supabaseServiceClient.rpc('complete_member_registration', {
			p_insurance_form_submitted: form.data.insuranceFormSubmitted,
			p_next_of_kin_name: form.data.nextOfKin,
			p_next_of_kin_phone: form.data.nextOfKinNumber,
			v_user_id: tokenClaim.sub!
		});

		if (error) {
			return setError(form, 'nextOfKin', 'There was an error updating your profile.');
		}
		return redirect(303, `/auth?message=${encodeURIComponent('Thanks for joining us!')}`);
	}
};
