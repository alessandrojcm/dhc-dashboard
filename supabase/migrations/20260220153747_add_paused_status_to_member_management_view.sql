DROP VIEW IF EXISTS public.member_management_view;

CREATE VIEW public.member_management_view WITH (security_invoker) AS
SELECT
	mp.*,
	mp.subscription_paused_until AS paused_until,
	CASE
		WHEN up.is_active = false THEN 'inactive'
		WHEN mp.subscription_paused_until IS NOT NULL
			AND mp.subscription_paused_until > NOW() THEN 'paused'
		ELSE 'active'
	END AS membership_status,
	up.first_name,
	up.last_name,
	up.phone_number,
	up.gender,
	up.pronouns,
	up.is_active,
	up.customer_id,
	up.medical_conditions,
	(
		SELECT email
		FROM public.get_email_from_auth_users(up.supabase_user_id)
	) AS email,
	w.id AS from_waitlist_id,
	w.initial_registration_date AS waitlist_registration_date,
	ARRAY_AGG(ur.role) AS roles,
	EXTRACT(year FROM AGE(up.date_of_birth)) AS age,
	up.search_text AS search_text,
	up.social_media_consent AS social_media_consent,
	wg.first_name AS guardian_first_name,
	wg.last_name AS guardian_last_name,
	wg.phone_number AS guardian_phone_number
FROM public.member_profiles mp
JOIN public.user_profiles up ON mp.user_profile_id = up.id
LEFT JOIN public.waitlist w ON up.waitlist_id = w.id
LEFT JOIN public.user_roles ur ON up.supabase_user_id = ur.user_id
LEFT JOIN public.waitlist_guardians wg ON wg.profile_id = up.id
GROUP BY mp.id, up.id, w.id, wg.id;
