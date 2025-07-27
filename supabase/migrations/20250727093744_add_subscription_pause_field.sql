-- Add subscription pause tracking to member_profiles
ALTER TABLE member_profiles 
ADD COLUMN subscription_paused_until TIMESTAMP WITH TIME ZONE DEFAULT NULL;

-- Add index for performance
CREATE INDEX idx_member_profiles_subscription_paused_until 
ON member_profiles(subscription_paused_until) 
WHERE subscription_paused_until IS NOT NULL;

-- Update member_management_view to include customer_id (subscription_paused_until is already included via mp.*)
DROP VIEW IF EXISTS public.member_management_view;
CREATE VIEW public.member_management_view with (security_invoker) AS
SELECT mp.*,
       up.first_name,
       up.last_name,
       up.phone_number,
       up.gender,
       up.pronouns,
       up.is_active,
       up.customer_id,  -- Add customer_id to view
       up.medical_conditions,
       (select email from public.get_email_from_auth_users(up.supabase_user_id)) as email,
       w.id as from_waitlist_id,
       w.initial_registration_date as waitlist_registration_date,
       array_agg(ur.role) as roles,
       extract(year from age(up.date_of_birth)) as age,
       up.search_text as search_text,
       up.social_media_consent as social_media_consent,
       wg.first_name as guardian_first_name,
       wg.last_name as guardian_last_name,
       wg.phone_number as guardian_phone_number
FROM public.member_profiles mp
JOIN public.user_profiles up ON mp.user_profile_id = up.id
LEFT JOIN public.waitlist w ON up.waitlist_id = w.id
LEFT JOIN public.user_roles ur ON up.supabase_user_id = ur.user_id
LEFT JOIN waitlist_guardians wg on wg.profile_id = up.id
GROUP BY mp.id, up.id, w.id, wg.id;

-- Add subscription pause settings
INSERT INTO settings (key, value, type, description) VALUES 
('subscription_max_pause_months', '6', 'text', 'Maximum months a subscription can be paused'),
('subscription_min_pause_days', '1', 'text', 'Minimum days a subscription can be paused');