import { PUBLIC_SITE_URL } from '$env/static/public';
import dayjs from 'dayjs';

export function getInvitationLink(invitationId: string, email?: string, dateOfBirth?: Date|string): string {
	const url = new URL(`${PUBLIC_SITE_URL}/members/signup/${invitationId}`);
	if (email) url.searchParams.set('email', email);
	if (dateOfBirth) url.searchParams.set('dateOfBirth', dayjs(dateOfBirth).format('YYYY-MM-DD'));
	return url.toString();
}
