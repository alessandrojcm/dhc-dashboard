-- Create a type to hold the member data
CREATE TYPE public.member_data_type AS (
    -- User profile data
    first_name TEXT,
    last_name TEXT,
    is_active BOOLEAN,
    medical_conditions TEXT,
    phone_number TEXT,
    gender TEXT,
    pronouns TEXT,
    date_of_birth DATE,
    -- Member profile data
    next_of_kin_name TEXT,
    next_of_kin_phone TEXT,
    preferred_weapon public.preferred_weapon[],
    membership_start_date TIMESTAMP WITH TIME ZONE,
    membership_end_date TIMESTAMP WITH TIME ZONE,
    last_payment_date TIMESTAMP WITH TIME ZONE,
    insurance_form_submitted BOOLEAN,
    additional_data JSONB
);

-- Create the stored procedure
CREATE OR REPLACE FUNCTION public.get_member_data(user_uuid UUID)
    RETURNS public.member_data_type
    SECURITY INVOKER
    LANGUAGE plpgsql
    SET search_path = ''
AS
$$
DECLARE
    result public.member_data_type;
BEGIN
    -- Get all the required data in one query
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
           mp.additional_data
    INTO result
    FROM public.user_profiles up
             JOIN public.member_profiles mp ON mp.user_profile_id = up.id
    WHERE up.supabase_user_id = user_uuid;

    -- Check if user was found
    IF result.first_name IS NULL THEN
        RAISE EXCEPTION 'User with UUID % not found', user_uuid;
    END IF;

    RETURN result;
EXCEPTION
    WHEN OTHERS THEN
        RAISE;
END;
$$;

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
    p_preferred_weapon public.preferred_weapon[] DEFAULT NULL,
    p_membership_start_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    p_membership_end_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    p_last_payment_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    p_insurance_form_submitted BOOLEAN DEFAULT NULL,
    p_additional_data JSONB DEFAULT NULL
)
    RETURNS public.member_data_type
    SECURITY INVOKER
    LANGUAGE plpgsql
    SET search_path = ''
AS
$$
DECLARE
    v_user_profile_id UUID;
    result public.member_data_type;
BEGIN
    -- First get the user_profile_id
    SELECT id INTO v_user_profile_id
    FROM public.user_profiles
    WHERE supabase_user_id = user_uuid;

    -- Check if user exists
    IF v_user_profile_id IS NULL THEN
        RAISE EXCEPTION 'User with UUID % not found', user_uuid;
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
        insurance_form_submitted = COALESCE(p_insurance_form_submitted, insurance_form_submitted),
        additional_data = COALESCE(p_additional_data, additional_data),
        updated_at = NOW()
    WHERE user_profile_id = v_user_profile_id;

    -- Return the updated data using the existing get_member_data function
    SELECT * INTO result FROM public.get_member_data(user_uuid);
    RETURN result;
EXCEPTION
    WHEN OTHERS THEN
        RAISE;
END;
$$;