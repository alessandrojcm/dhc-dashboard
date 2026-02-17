import * as Sentry from '@sentry/sveltekit';
import { error, type ServerLoadEvent } from '@sveltejs/kit';
import dayjs from 'dayjs';
import { invariant } from '$lib/server/invariant';
import { getRolesFromSession, SETTINGS_ROLES } from '$lib/server/roles';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { SocialMediaConsent } from '$lib/types.ts';
import type { RequestEvent } from '../$types';
import type { PageServerLoad } from './$types';
import { createMemberService } from '$lib/server/services/members';

async function canUpdateSettings(event: RequestEvent | ServerLoadEvent) {
	const { session } = await event.locals.safeGetSession();
	invariant(session === null, 'Unauthorized');
	const roles = getRolesFromSession(session!);
	if (roles.intersection(SETTINGS_ROLES).size > 0) {
		return true;
	}
	const {
		data: { user },
		error
	} = await event.locals.supabase.auth.getUser();

	if (error || user?.id !== event.locals.session?.user.id) {
		return false;
	}
	return true;
}

export const load: PageServerLoad = async (event) => {
	const { params, locals, platform } = event;
	const { session } = await locals.safeGetSession();

	if (!session || !platform?.env.HYPERDRIVE) {
		return error(401, 'Unauthorized');
	}

	try {
		const canUpdate = await canUpdateSettings(event);
		const memberService = createMemberService(platform, session);

		// Get member data
		const memberProfile = await memberService.findById(params.memberId);

		if (!canUpdate && (!memberProfile || params.memberId !== locals.session?.user.id)) {
			return error(404, 'Member not found');
		}

		const email = await supabaseServiceClient.auth.admin
			.getUserById(params.memberId)
			.then((r) => r.data.user?.email ?? '');

		// Get member data with subscription info
		const memberData = await memberService.findByIdWithSubscription(params.memberId);

		return {
			profileData: {
				firstName: memberProfile.first_name ?? '',
				lastName: memberProfile.last_name ?? '',
				email,
				phoneNumber: memberProfile.phone_number ?? '',
				dateOfBirth: memberProfile.date_of_birth
					? dayjs(memberProfile.date_of_birth).format('YYYY-MM-DD')
					: '',
				pronouns: memberProfile.pronouns ?? '',
				gender: memberProfile.gender ?? '',
				medicalConditions: memberProfile.medical_conditions ?? '',
				nextOfKin: memberProfile.next_of_kin_name ?? '',
				nextOfKinNumber: memberProfile.next_of_kin_phone ?? '',
				weapon: (memberProfile.preferred_weapon as string[]) ?? [],
				insuranceFormSubmitted: memberProfile.insurance_form_submitted ?? false,
				socialMediaConsent: memberProfile.social_media_consent as SocialMediaConsent | undefined
			},
			genders: locals.supabase.rpc('get_gender_options').then((r) => r.data ?? []) as Promise<
				string[]
			>,
			weapons: locals.supabase.rpc('get_weapons_options').then((r) => r.data ?? []) as Promise<
				string[]
			>,
			insuranceFormLink: supabaseServiceClient
				.from('settings')
				.select('value')
				.eq('key', 'insurance_form_link')
				.limit(1)
				.single()
				.then((result) => result.data?.value),
			member: {
				id: params.memberId,
				customer_id: memberData?.customer_id,
				subscription_paused_until: memberData?.subscription_paused_until
			},
			canUpdate
		};
	} catch (e) {
		Sentry.captureMessage(`Error loading member data: ${e}`, 'error');
		error(404, {
			message: 'Member not found'
		});
	}
};
