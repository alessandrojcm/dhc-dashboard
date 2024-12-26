import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';
import type { LayoutServerLoad } from './$types';
import { invariant } from '$lib/server/invariant';
import type { User } from '@supabase/supabase-js';

export const load: LayoutServerLoad = async ({ url }) => {
	const accessToken = url.searchParams.get('access_token');
	invariant(accessToken === null, `${url.pathname}?error_description=missing_access_token`);
	const tokenClaim = jwtDecode(accessToken!);
	invariant(
		dayjs.unix(tokenClaim.exp!).isBefore(dayjs()),
		`${url.pathname}?error_description=expired_access_token`
	);

	const userData = await supabaseServiceClient.auth.admin.getUserById(tokenClaim.sub!);
	invariant(userData.error || !userData.data?.user, 'This invite is not valid');

	// This is ok as we already asserted there is no error
	return { userData: userData.data.user as unknown as User };
};
