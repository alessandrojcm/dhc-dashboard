-- Parameters:
--   uid - The UUID of the user to check
-- Returns:
--   JSONB containing user information
--   Success: {'first_name': string, 'last_name': string, ...}
create or replace function get_membership_info(uid uuid)
    returns jsonb
    language plpgsql
    security definer
    set search_path = public
as
$$
declare
    v_result jsonb;
    v_banned_until timestamptz;
    v_waitlist_id uuid;
    v_member_id uuid;
    v_is_active boolean;
    v_first_name text;
    v_last_name text;
    v_phone_number text;
    v_date_of_birth timestamptz;
    v_pronouns text;
    v_gender text;
    v_email text;
begin
    -- Get all information in one query for better performance and consistency
    with user_info as (
        select 
            u.email,
            u.banned_until,
            up.waitlist_id as waitlist_id,
            mp.id as member_id,
            coalesce(up.is_active, false) as is_active,
            up.first_name,
            up.last_name,
            up.phone_number,
            up.date_of_birth,
            up.pronouns,
            up.gender
        from auth.users u
        left join public.user_profiles up on up.supabase_user_id = u.id
        left join public.member_profiles mp on mp.user_profile_id = up.id
        where u.id = uid
    )
    select 
        email, banned_until, waitlist_id, member_id, is_active,
        first_name, last_name, phone_number, date_of_birth, pronouns, gender
    into strict
        v_email, v_banned_until, v_waitlist_id, v_member_id, v_is_active,
        v_first_name, v_last_name, v_phone_number, v_date_of_birth, v_pronouns, v_gender
    from user_info;

    raise log 'Debug values: email=%, waitlist_id=%, member_id=%, is_active=%', 
        v_email, v_waitlist_id, v_member_id, v_is_active;

    -- Check conditions in order
    if v_banned_until > now() then
        raise exception using
            errcode = 'U0003',
            message = 'User is banned.',
            hint = 'Banned until: ' || v_banned_until;
    end if;

    if v_member_id is not null then
        raise exception using
            errcode = 'U0004',
            message = 'User already has a member profile.',
            hint = 'Member ID: ' || v_member_id;
    end if;

    if v_is_active then
        raise exception using
            errcode = 'U0005',
            message = 'User is already active.';
    end if;

    if v_waitlist_id is null then
        raise exception using
            errcode = 'U0006',
            message = format('Waitlist entry not found for email: %s', v_email),
            hint = 'Email not found in waitlist';
    end if;

    -- Build the result JSONB only after all checks pass
    return jsonb_build_object(
        'first_name', v_first_name,
        'last_name', v_last_name,
        'phone_number', v_phone_number,
        'date_of_birth', v_date_of_birth,
        'pronouns', v_pronouns,
        'gender', v_gender
    );
exception
    when no_data_found then
        raise exception using
            errcode = 'U0002',
            message = 'User not found.';
    when others then
        raise;
end;
$$;

-- Function to create a pending member (before payment confirmation)
create or replace function create_pending_member(
    uid uuid,
    -- User profile information
    first_name text,
    last_name text,
    phone_number text,
    date_of_birth timestamptz,
    pronouns text,
    gender public.gender,
    medical_conditions text,
    -- Member specific information
    next_of_kin_name text,
    next_of_kin_phone text,
    preferred_weapon public.preferred_weapon[],
    additional_data jsonb default '{}'::jsonb
)
    returns jsonb
    language plpgsql
    security definer
    set search_path = public
as
$$
declare
    v_user_profile_id uuid;
    v_member_id uuid;
    v_membership_info jsonb;
begin
    -- Get membership eligibility info
    -- This will throw if any of the conditions are not met
    perform get_membership_info(uid);

    -- Update user profile and set active status to false
    update public.user_profiles 
    set is_active = false,
        first_name = create_pending_member.first_name,
        last_name = create_pending_member.last_name,
        phone_number = create_pending_member.phone_number,
        date_of_birth = create_pending_member.date_of_birth,
        pronouns = create_pending_member.pronouns,
        gender = create_pending_member.gender,
        medical_conditions = create_pending_member.medical_conditions,
        updated_at = now()
    where supabase_user_id = uid
    returning id into v_user_profile_id;

    if v_user_profile_id is null then
        raise exception 'User profile not found.' using errcode = 'U0007';
    end if;

    -- Create member profile
    insert into public.member_profiles (
        id,
        user_profile_id,
        next_of_kin_name,
        next_of_kin_phone,
        preferred_weapon,
        additional_data
    )
    values (
        uid,
        v_user_profile_id,
        next_of_kin_name,
        next_of_kin_phone,
        preferred_weapon,
        additional_data
    )
    returning id into v_member_id;

    -- Return success response with updated profile information
    return jsonb_build_object(
        'member_id', v_member_id,
        'profile', jsonb_build_object(
            'first_name', first_name,
            'last_name', last_name,
            'phone_number', phone_number,
            'date_of_birth', date_of_birth,
            'pronouns', pronouns,
            'gender', gender,
            'medical_conditions', medical_conditions,
            'next_of_kin_name', next_of_kin_name,
            'next_of_kin_phone', next_of_kin_phone,
            'preferred_weapon', preferred_weapon,
            'insurance_form_submitted', false
        ),
        'message', 'Pending member created successfully. Membership will be activated upon payment confirmation.'
    );
end;
$$;

create or replace function get_weapons_options()
    returns json
    language plpgsql
    set search_path = public
as
$$
DECLARE
    options json;
begin
    select json_agg(enumlabel) as weapon_options
    into options
    from pg_enum
    where enumtypid = 'public.preferred_weapon'::regtype;
    return options;
end;
$$;
