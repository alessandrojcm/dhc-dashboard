import { invariant } from '$lib/server/invariant';
import { type RequestHandler } from '@sveltejs/kit';
import dayjs from 'dayjs';
import { jwtDecode } from 'jwt-decode';

export const POST: RequestHandler = async (event) => {
	const accessToken = event.request.headers.get('Authorization')?.replace('Bearer ', '');
	const tokenClaim = jwtDecode(accessToken!);
	invariant(
		dayjs.unix(tokenClaim.exp!).isBefore(dayjs()),
		`${event.url.pathname}?error_description=expired_access_token`
	);
	return new Response(null, {
		status: 302,
		headers: {
			'Set-Cookie': event.cookies.serialize('access-token', accessToken!, {
				path: '/',
				expires: dayjs.unix(tokenClaim.exp!).toDate()
			}),
			Location: '/members/signup'
		}
	});
};
