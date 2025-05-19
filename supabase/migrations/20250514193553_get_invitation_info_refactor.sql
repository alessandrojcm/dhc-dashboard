drop function get_invitation_info(p_user_id UUID);

-- Modify get_invitation_info to handle race conditions
CREATE OR REPLACE FUNCTION public.get_invitation_info(
    p_invitation_id UUID
)
    RETURNS JSONB
    LANGUAGE plpgsql
    SECURITY INVOKER
    SET search_path = ''
AS
$$
DECLARE
    v_result                JSONB;
    v_user_email            TEXT;
    v_banned_until          TIMESTAMPTZ;
    v_member_id             UUID;
    v_is_active             BOOLEAN;
    v_invitation_status     public.invitation_status;
    v_invitation_expires_at TIMESTAMPTZ;
    v_first_name            TEXT;
    v_last_name             TEXT;
    v_phone_number          TEXT;
    v_date_of_birth         TIMESTAMPTZ;
    v_pronouns              TEXT;
    v_gender                TEXT;
    v_medical_conditions    TEXT;
    v_user_id               UUID;
    v_customer_id           text;
BEGIN
    -- Check for valid invitation with FOR UPDATE to lock the row
    SELECT i.status,
           i.expires_at,
           i.user_id
    INTO
        v_invitation_status, v_invitation_expires_at, v_user_id
    FROM public.invitations i
    WHERE i.id = p_invitation_id
      AND i.status = 'pending'
    ORDER BY i.created_at DESC
    LIMIT 1 FOR UPDATE;
    -- Lock the row to prevent race conditions

    IF v_user_id is null THEN
        RAISE EXCEPTION USING
            errcode = 'NOTFOUND1',
            message = 'Invitation not found';
    end if;

    -- Check if this is a service role or if the user is trying to get their own invitation info
    IF NOT (
               v_user_id = (select auth.uid()) OR
               (select current_role) IN ('postgres', 'service_role') OR
       public.has_any_role((select auth.uid()),
                           ARRAY ['admin', 'president', 'committee_coordinator']::public.role_type[])
        ) THEN
        RAISE EXCEPTION USING
            errcode = 'PERM1',
            message = 'Permission denied: Cannot access invitation info for another user';
    END IF;

    -- Get user email and banned status
    SELECT email, banned_until
    INTO v_user_email, v_banned_until
    FROM auth.users
    WHERE id = v_user_id
        FOR UPDATE;
    -- Lock the row to prevent race conditions

    -- Check if user is banned
    IF v_banned_until > now() THEN
        RAISE EXCEPTION USING
            errcode = 'U0003',
            message = 'User is banned.',
            hint = 'Banned until: ' || v_banned_until;
    END IF;

    -- Check if user already has a member profile
    -- First lock the user_profiles row if it exists
    SELECT id, customer_id
    INTO v_member_id, v_customer_id
    FROM public.user_profiles
    WHERE supabase_user_id = v_user_id
        FOR UPDATE;

    -- Then get the member profile info if the user profile exists
    IF v_member_id IS NOT NULL THEN
        -- Get member profile info
        SELECT mp.id, up.is_active
        INTO v_member_id, v_is_active
        FROM public.user_profiles up
                 LEFT JOIN public.member_profiles mp ON mp.user_profile_id = up.id
        WHERE up.supabase_user_id = v_user_id;

        IF v_member_id IS NOT NULL THEN
            RAISE EXCEPTION USING
                errcode = 'U0004',
                message = 'User already has a member profile.',
                hint = 'Member ID: ' || v_member_id;
        END IF;

        IF v_is_active THEN
            RAISE EXCEPTION USING
                errcode = 'U0005',
                message = 'User is already active.';
        END IF;
    END IF;

    IF v_invitation_expires_at < now() THEN
        -- Update invitation status to expired
        UPDATE public.invitations
        SET status     = 'expired',
            updated_at = now()
        WHERE id = p_invitation_id;

        RAISE EXCEPTION USING
            errcode = 'U0009',
            message = 'Invitation has expired.',
            hint = 'Please request a new invitation';
    END IF;

    SELECT up.first_name,
           up.last_name,
           up.phone_number,
           up.date_of_birth,
           up.pronouns,
           up.gender,
           up.medical_conditions
    INTO
        v_first_name, v_last_name, v_phone_number,
        v_date_of_birth, v_pronouns, v_gender,
        v_medical_conditions
    FROM public.user_profiles up
    WHERE up.supabase_user_id = v_user_id;

    -- Build the result JSON
    v_result := jsonb_build_object(
            'invitation_id', p_invitation_id,
            'status', v_invitation_status,
            'expires_at', v_invitation_expires_at,
            'first_name', v_first_name,
            'last_name', v_last_name,
            'phone_number', v_phone_number,
            'date_of_birth', v_date_of_birth,
            'pronouns', v_pronouns,
            'gender', v_gender,
            'medical_conditions', v_medical_conditions,
            'user_id', v_user_id,
            'customer_id', v_customer_id,
            'email', v_user_email
                );

    RETURN v_result;
EXCEPTION
    WHEN no_data_found THEN
        RAISE EXCEPTION USING
            errcode = 'U0002',
            message = 'User not found.';
    WHEN others THEN
        RAISE;
END;
$$;
