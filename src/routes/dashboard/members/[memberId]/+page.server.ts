import type { Database } from '$database';
import signupSchema from '$lib/schemas/membersSignup';
import { executeWithRLS, kysely } from '$lib/server/kysely';
import { getMemberData, updateMemberData } from '$lib/server/kyselyRPCFunctions';
import { stripeClient } from '$lib/server/stripe';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import { error, redirect, type Actions } from '@sveltejs/kit';
import { fail, message, setError, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ params, locals }) => {
	try {
		const memberProfile = await getMemberData(params.memberId, kysely);
		const email = locals.session?.user.email;

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
					insuranceFormSubmitted: memberProfile.insurance_form_submitted,
					socialMediaConsent: memberProfile.social_media_consent
				},
				valibot(signupSchema),
				{ errors: false }
			),
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
				.then((result) => result.data?.value)
		};
	} catch (e) {
		console.error(e);
		error(404, {
			message: 'Member not found'
		});
	}
};

export const actions: Actions = {
	'update-profile': async (event) => {
		const form = await superValidate(event, valibot(signupSchema));
		if (!form.valid) {
			return fail(422, {
				form
			});
		}
		try {
			await executeWithRLS(
				{
					claims: event.locals.session!.user!
				},
				async (trx) => {
					// Get current user data for comparison
					const currentUser = await trx
						.selectFrom('user_profiles')
						.select(['first_name', 'last_name', 'phone_number', 'customer_id'])
						.where('supabase_user_id', '=', event.params.memberId!)
						.limit(1)
						.execute()
						.then((result) => result[0]);

					if (!currentUser?.customer_id) {
						throw new Error('Customer ID not found');
					}

					// Update member data
					await updateMemberData(
						{
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
							p_preferred_weapon: form.data
								.weapon as Database['public']['Enums']['preferred_weapon'][],
							p_insurance_form_submitted: form.data.insuranceFormSubmitted,
							p_social_media_consent: form.data
								.socialMediaConsent as Database['public']['Enums']['social_media_consent']
						},
						trx
					);

					// Check if name or phone number changed
					const currentName = `${currentUser.first_name} ${currentUser.last_name}`.trim();
					const newName = `${form.data.firstName} ${form.data.lastName}`.trim();
					const nameChanged = currentName !== newName;
					const phoneChanged = currentUser.phone_number !== form.data.phoneNumber;

					// Only update Stripe if necessary
					if (nameChanged || phoneChanged) {
						await stripeClient.customers.update(currentUser.customer_id, {
							...(nameChanged && { name: newName }),
							...(phoneChanged && { phone: form.data.phoneNumber })
						});
					}
				}
			);

			return message(form, { success: 'Profile has been updated!' });
		} catch (err) {
			console.error('Error updating member profile:', err);
			return setError(form, 'There was an error updating your profile. Please try again later.');
		}
	},
	'payment-settings': async (event) => {
		const memberId = event.params.memberId!;
		const customerId = await kysely
			.selectFrom('user_profiles')
			.select('customer_id')
			.where('supabase_user_id', '=', memberId)
			.limit(1)
			.execute()
			.then((result) => result[0]?.customer_id);

		if (!customerId) {
			return fail(404, {
				message: 'Member not found'
			});
		}
		const billingPortalSession = await stripeClient.billingPortal.sessions.create({
			customer: customerId,
			return_url: `${event.url.origin}/dashboard/members/${memberId}`
		});
		return redirect(303, billingPortalSession.url);
	}
};
