import type { PageServerLoad } from './$types';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient.js';
import { jwtDecode } from 'jwt-decode';
import { redirect } from '@sveltejs/kit';
import dayjs from 'dayjs';
import * as url from 'node:url';

function invariant(condition: unknown, url: string): asserts condition {
	if (!condition) {
		throw redirect(301, url);
	}
}
// need to normalize medical_conditions
export const load: PageServerLoad = async ({ url }) => {
	const accessToken = url.searchParams.get('access_token');
	invariant(accessToken === null, `${url.pathname}?error=missing_access_token`);
	const tokenClaim = jwtDecode(accessToken!);
	invariant(
		dayjs.unix(tokenClaim.exp!).isBefore(dayjs()),
		`${url.pathname}?error=expired_access_token`
	);

	const userData = await supabaseServiceClient.auth.admin.getUserById(tokenClaim.sub!);
	invariant(userData.error || !userData.data?.user, `${url.pathname}?error=invalid_access_token`);

	// Is this an active user?
	const userProfile = await supabaseServiceClient
		.from('user_profiles')
		.select('first_name,last_name,phone_number,date_of_birth, pronouns, gender, is_active')
		.eq('supabase_user_id', userData.data.user!.id)
		.single();
	invariant(userProfile.error !== null, `${url}?error=error_fetching_user`);
	console.log(userProfile);
};
