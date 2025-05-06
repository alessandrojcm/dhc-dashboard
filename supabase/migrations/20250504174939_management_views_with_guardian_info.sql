drop view if exists waitlist_management_view;
create view waitlist_management_view with (security_invoker) as
select w.*,
       u.search_text                          as search_text,
       u.phone_number                         as phone_number,
       u.medical_conditions                   as medical_conditions,
       concat(u.first_name, ' ', u.last_name) as full_name,
       get_waitlist_position(w.id)            as current_position,
       extract(
               year
               from age(u.date_of_birth)
       )                                      as age,
       u.social_media_consent                 as social_media_consent,
       wg.first_name                          as guardian_first_name,
       wg.last_name                           as guardian_last_name,
       wg.phone_number                        as guardian_phone_number
from user_profiles u
         join waitlist w on u.waitlist_id = w.id
         left join waitlist_guardians wg on wg.profile_id = u.id
where u.waitlist_id is not null;

-- Helper view for member management
DROP VIEW IF EXISTS public.member_management_view;
CREATE VIEW public.member_management_view with (security_invoker) AS
SELECT mp.*,
       up.first_name,
       up.last_name,
       up.phone_number,
       up.gender,
       up.pronouns,
       up.is_active,
       (select email from public.get_email_from_auth_users(up.supabase_user_id)) as email,
       w.id                                                                      as from_waitlist_id,
       w.initial_registration_date                                               as waitlist_registration_date,
       array_agg(ur.role)                                                        as roles,
       extract(year from age(up.date_of_birth))                                  as age,
       up.search_text                                                            as search_text,
       up.social_media_consent                                                   as social_media_consent,
       wg.first_name                                                             as guardian_first_name,
       wg.last_name                                                              as guardian_last_name,
       wg.phone_number                                                           as guardian_phone_number
FROM public.member_profiles mp
         JOIN public.user_profiles up ON mp.user_profile_id = up.id
         LEFT JOIN public.waitlist w ON up.waitlist_id = w.id
         LEFT JOIN public.user_roles ur ON up.supabase_user_id = ur.user_id
         left join waitlist_guardians wg on wg.profile_id = up.id
GROUP BY mp.id,
         up.id,
         w.id,
         wg.id;