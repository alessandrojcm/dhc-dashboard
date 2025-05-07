DROP FUNCTION IF EXISTS complete_member_registration;


-- Function to complete member registration
CREATE OR REPLACE FUNCTION public.complete_member_registration(
    v_user_id UUID,
    p_next_of_kin_name TEXT,
    p_next_of_kin_phone TEXT,
    p_insurance_form_submitted BOOLEAN
) RETURNS UUID
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS
$$
DECLARE
    p_user_profile_id UUID;
    p_waitlist_id UUID;
    v_member_id       UUID;
BEGIN

    SELECT id, waitlist_id
    into p_user_profile_id, p_waitlist_id
    FROM public.user_profiles
    WHERE supabase_user_id = v_user_id;

    if p_user_profile_id is null then
        RAISE EXCEPTION 'User not found';
    end if;

    IF p_insurance_form_submitted IS FALSE THEN
        RAISE EXCEPTION 'You must submit the insurance form';
    END IF;

    -- Create member profile
    INSERT INTO public.member_profiles (id,
                                        user_profile_id,
                                        next_of_kin_name,
                                        next_of_kin_phone,
                                        preferred_weapon,
                                        insurance_form_submitted)
    VALUES (v_user_id,
            p_user_profile_id,
            p_next_of_kin_name,
            p_next_of_kin_phone,
            ARRAY []::public.preferred_weapon[],
            p_insurance_form_submitted)
    RETURNING id INTO v_member_id;

    UPDATE public.user_profiles
    SET is_active = true
    WHERE id = p_user_profile_id;

    IF p_waitlist_id IS NOT NULL THEN
        UPDATE public.waitlist
        SET status = 'invited'
        WHERE id = p_waitlist_id;
    END IF;

    -- Add member role
    INSERT INTO public.user_roles (user_id, role)
    VALUES (v_user_id, 'member'::public.role_type);

    RETURN v_member_id;
END;
$$;

