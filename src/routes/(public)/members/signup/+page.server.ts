import signupSchema from '$lib/schemas/membersSignup';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient.js';
import { error } from '@sveltejs/kit';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import { superValidate } from 'sveltekit-superforms';
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
			form: await superValidate(
				{
					firstName: data?.first_name,
					lastName: data?.last_name,
					email: userData.data.user!.email,
					dateOfBirth: new Date(data?.date_of_birth),
					phoneNumber: data?.phone_number,
					pronouns: data?.pronouns,
					gender: data?.gender,
					medicalConditions: data?.medical_conditions
				},
				valibot(signupSchema),
				{ errors: false }
			)
		};
	} catch (err) {
		error(404, {
			message: 'Waitlist entry not found'
		});
	}
};

export const actions: Actions = {
	default: async (event) => {
		//  TODO: this
		return superValidate(event, valibot(signupSchema));
	}
};
