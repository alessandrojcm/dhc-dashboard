-- Create a type to hold the member data
CREATE TYPE public.member_data_type AS (
    -- User profile data
    first_name TEXT,
    last_name TEXT,
    is_active BOOLEAN,
    medical_conditions TEXT,
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