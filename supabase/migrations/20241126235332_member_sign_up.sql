-- Parameters:
--   uid - The UUID of the user to check
-- Returns:
--   JSONB containing user information
--   Success: {'first_name': string, 'last_name': string, ...}
create or replace function get_membership_info(uid uuid)
    returns jsonb
    language plpgsql
    security definer
    stable
    set search_path = public
as
$$
declare
    v_result jsonb;
    v_banned_until timestamptz;
    v_waitlist_id uuid;
    v_member_id uuid;
    v_is_active boolean;
begin
    if uid is null then
        raise sqlstate 'U0001' using message = 'User ID cannot be null.';
    end if;

    if not exists (select 1 from auth.users where id = uid) then
        raise sqlstate 'U0002' using message = 'User not found.';
    end if;

    -- Get all the necessary information in one query
    select 
        u.banned_until,
        w.id as waitlist_id,
        mp.id as member_id,
        up.is_active,
        case 
            when mp.id is not null then null -- Will be handled below
            else jsonb_build_object(
                'first_name', up.first_name,
                'last_name', up.last_name,
                'phone_number', up.phone_number,
                'date_of_birth', up.date_of_birth,
                'pronouns', up.pronouns,
                'gender', up.gender
            )
        end as profile_info
    into v_banned_until, v_waitlist_id, v_member_id, v_is_active, v_result
    from auth.users u
    left join public.waitlist w on w.email = u.email
    left join public.user_profiles up on up.waitlist_id = w.id
    left join public.member_profiles mp on mp.user_profile_id = up.id
    where u.id = uid;

    -- Check conditions in order
    if v_banned_until > now() then
        raise sqlstate 'U0003' using message = 'User is banned.';
    end if;

    if v_member_id is not null then
        raise sqlstate 'U0004' using message = 'User already has a member profile.';
    end if;

    if v_is_active then
        raise sqlstate 'U0005' using message = 'User is already active.';
    end if;

    if v_waitlist_id is null then
        raise sqlstate 'U0006' using message = 'Waitlist entry not found.';
    end if;

    return v_result;
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
        raise sqlstate 'U0007' using message = 'User profile not found.';
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

exception
    -- Handle exceptions from get_membership_info
    when sqlstate 'U0001' then
        raise;
    when sqlstate 'U0002' then
        raise;
    when sqlstate 'U0003' then
        raise;
    when sqlstate 'U0004' then
        raise;
    when sqlstate 'U0005' then
        raise;
    when sqlstate 'U0006' then
        raise;
    when sqlstate 'U0007' then
        raise;
    when others then
        raise;
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