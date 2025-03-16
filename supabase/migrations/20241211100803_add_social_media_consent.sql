-- Create enum type for social media consent
CREATE TYPE social_media_consent AS ENUM ('no', 'yes_recognizable', 'yes_unrecognizable');
-- Add social_media_consent field to user_profiles
ALTER TABLE public.user_profiles
ADD COLUMN social_media_consent social_media_consent DEFAULT 'no';
-- Add comment to explain the field's purpose
COMMENT ON COLUMN public.user_profiles.social_media_consent IS 'Indicates whether and how the user has consented to appear in social media posts';
-- Drop old function
DROP FUNCTION IF EXISTS insert_waitlist_entry;
create or replace function insert_waitlist_entry(
        first_name text,
        last_name text,
        email text,
        date_of_birth timestamptz,
        phone_number text,
        pronouns text,
        gender public.gender,
        medical_conditions text,
        social_media_consent public.social_media_consent DEFAULT 'no'
    ) returns table (
        profile_id uuid,
        waitlist_id uuid,
        user_first_name text,
        user_last_name text,
        user_email text,
        user_date_of_birth date,
        user_phone_number text,
        user_pronouns text,
        user_gender public.gender,
        user_medical_conditions text,
        user_social_media_consent public.social_media_consent
    ) language plpgsql
set search_path = '' as $$
declare new_waitlist_id uuid;
begin begin
insert into public.waitlist (email)
values (email)
returning id into new_waitlist_id;
insert into public.user_profiles (
        first_name,
        last_name,
        date_of_birth,
        phone_number,
        pronouns,
        gender,
        is_active,
        waitlist_id,
        medical_conditions,
        social_media_consent
    )
values (
        first_name,
        last_name,
        date_of_birth,
        phone_number,
        pronouns,
        gender,
        false,
        new_waitlist_id,
        medical_conditions,
        social_media_consent
    );
RETURN QUERY
SELECT u.id AS profile_id,
    w.id AS waitlist_id,
    u.first_name AS user_first_name,
    u.last_name AS user_last_name,
    w.email AS user_email,
    u.date_of_birth AS user_date_of_birth,
    u.phone_number AS user_phone_number,
    u.pronouns AS user_pronouns,
    u.gender AS user_gender,
    u.medical_conditions AS user_medical_conditions,
    u.social_media_consent AS user_social_media_consent
FROM public.waitlist w
    JOIN public.user_profiles u ON w.id = u.waitlist_id
WHERE w.id = new_waitlist_id;
exception
when others then raise;
end;
end;
$$;
DROP FUNCTION IF EXISTS get_member_data;
-- Alter the existing type to add the new field
ALTER TYPE public.member_data_type
ADD ATTRIBUTE social_media_consent public.social_media_consent;
-- Create the stored procedure
CREATE OR REPLACE FUNCTION public.get_member_data(user_uuid UUID) RETURNS public.member_data_type SECURITY INVOKER LANGUAGE plpgsql
SET search_path = '' AS $$
DECLARE result public.member_data_type;
BEGIN -- Get all the required data in one query
SELECT up.first_name,
    up.last_name,
    up.is_active,
    up.medical_conditions,
    up.phone_number,
    up.gender,
    up.pronouns,
    up.date_of_birth,
    mp.next_of_kin_name,
    mp.next_of_kin_phone,
    mp.preferred_weapon,
    mp.membership_start_date,
    mp.membership_end_date,
    mp.last_payment_date,
    mp.insurance_form_submitted,
    mp.additional_data,
    up.social_media_consent INTO result
FROM public.user_profiles up
    JOIN public.member_profiles mp ON mp.user_profile_id = up.id
WHERE up.supabase_user_id = user_uuid;
-- Check if user was found
IF result.first_name IS NULL THEN RAISE EXCEPTION 'User with UUID % not found',
user_uuid;
END IF;
RETURN result;
EXCEPTION
WHEN OTHERS THEN RAISE;
END;
$$;
DROP FUNCTION IF EXISTS update_member_data;
-- Create the update stored procedure
CREATE OR REPLACE FUNCTION public.update_member_data(
        user_uuid UUID,
        p_first_name TEXT DEFAULT NULL,
        p_last_name TEXT DEFAULT NULL,
        p_is_active BOOLEAN DEFAULT NULL,
        p_medical_conditions TEXT DEFAULT NULL,
        p_phone_number TEXT DEFAULT NULL,
        p_gender public.gender DEFAULT NULL,
        p_pronouns TEXT DEFAULT NULL,
        p_date_of_birth DATE DEFAULT NULL,
        p_next_of_kin_name TEXT DEFAULT NULL,
        p_next_of_kin_phone TEXT DEFAULT NULL,
        p_preferred_weapon public.preferred_weapon [] DEFAULT NULL,
        p_membership_start_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
        p_membership_end_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
        p_last_payment_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
        p_insurance_form_submitted BOOLEAN DEFAULT NULL,
        p_additional_data JSONB DEFAULT NULL,
        p_social_media_consent public.social_media_consent DEFAULT 'no'
    ) RETURNS public.member_data_type SECURITY INVOKER LANGUAGE plpgsql
SET search_path = '' AS $$
DECLARE v_user_profile_id UUID;
result public.member_data_type;
BEGIN -- First get the user_profile_id
SELECT id INTO v_user_profile_id
FROM public.user_profiles
WHERE supabase_user_id = user_uuid;
-- Check if user exists
IF v_user_profile_id IS NULL THEN RAISE EXCEPTION 'User with UUID % not found',
user_uuid;
END IF;
-- Update user_profiles table
UPDATE public.user_profiles
SET first_name = COALESCE(p_first_name, first_name),
    last_name = COALESCE(p_last_name, last_name),
    is_active = COALESCE(p_is_active, is_active),
    medical_conditions = COALESCE(p_medical_conditions, medical_conditions),
    phone_number = COALESCE(p_phone_number, phone_number),
    gender = COALESCE(p_gender, gender),
    pronouns = COALESCE(p_pronouns, pronouns),
    date_of_birth = COALESCE(p_date_of_birth, date_of_birth),
    social_media_consent = COALESCE(p_social_media_consent, social_media_consent),
    updated_at = NOW()
WHERE id = v_user_profile_id;
-- Update member_profiles table
UPDATE public.member_profiles
SET next_of_kin_name = COALESCE(p_next_of_kin_name, next_of_kin_name),
    next_of_kin_phone = COALESCE(p_next_of_kin_phone, next_of_kin_phone),
    preferred_weapon = COALESCE(p_preferred_weapon, preferred_weapon),
    membership_start_date = COALESCE(p_membership_start_date, membership_start_date),
    membership_end_date = COALESCE(p_membership_end_date, membership_end_date),
    last_payment_date = COALESCE(p_last_payment_date, last_payment_date),
    insurance_form_submitted = COALESCE(
        p_insurance_form_submitted,
        insurance_form_submitted
    ),
    additional_data = COALESCE(p_additional_data, additional_data),
    updated_at = NOW()
WHERE user_profile_id = v_user_profile_id;
-- Return the updated data using the existing get_member_data function
SELECT * INTO result
FROM public.get_member_data(user_uuid);
RETURN result;
EXCEPTION
WHEN OTHERS THEN RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_email_from_auth_users(user_id uuid) 
RETURNS TABLE(email varchar(255)) 
SECURITY definer 
LANGUAGE plpgsql 
SET search_path = '' 
AS $$
BEGIN
    RETURN QUERY
    SELECT au.email::varchar(255)
    FROM auth.users au
    WHERE au.id = user_id;
END;
$$;

-- Helper view for member management
DROP VIEW IF EXISTS public.member_management_view;
CREATE VIEW public.member_management_view with (security_invoker) AS 
WITH current_user_id AS (
    SELECT auth.uid() as uid
)
SELECT 
    mp.*,
    up.first_name,
    up.last_name,
    up.phone_number,
    up.gender,
    up.pronouns,
    up.is_active,
    (select email from public.get_email_from_auth_users(up.supabase_user_id)) as email,
    w.id as from_waitlist_id,
    w.initial_registration_date as waitlist_registration_date,
    array_agg(ur.role) as roles,
    extract(year from age(up.date_of_birth)) as age,
    up.search_text as search_text,
    up.social_media_consent as social_media_consent
FROM public.member_profiles mp
    JOIN public.user_profiles up ON mp.user_profile_id = up.id
    LEFT JOIN public.waitlist w ON up.waitlist_id = w.id
    LEFT JOIN public.user_roles ur ON up.supabase_user_id = ur.user_id
GROUP BY mp.id,
    up.id,
    w.id;

drop view if exists waitlist_management_view;
create view waitlist_management_view with (security_invoker) as
select w.*,
    u.search_text as search_text,
    u.phone_number as phone_number,
    u.medical_conditions as medical_conditions,
    concat(u.first_name, ' ', u.last_name) as full_name,
    get_waitlist_position(w.id) as current_position,
    extract(
        year
        from age(u.date_of_birth)
    ) as age,
    u.social_media_consent as social_media_consent
from user_profiles u
    join waitlist w on u.waitlist_id = w.id
where u.waitlist_id is not null;