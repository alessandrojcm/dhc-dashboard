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
    v_waitlist_status public.waitlist_status;
begin
    -- Get all information in one query for better performance and consistency
    with user_info as (
        select 
            u.email,
            u.banned_until,
            up.waitlist_id as waitlist_id,
            mp.id as member_id,
            w.status as waitlist_status,
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
        left join public.waitlist w on w.id = up.waitlist_id
        where u.id = uid
    )
    select 
        email, banned_until, waitlist_id, member_id, waitlist_status, is_active,
        first_name, last_name, phone_number, date_of_birth, pronouns, gender
    into strict
        v_email, v_banned_until, v_waitlist_id, v_member_id, v_waitlist_status, v_is_active,
        v_first_name, v_last_name, v_phone_number, v_date_of_birth, v_pronouns, v_gender
    from user_info;

    raise log 'Debug values: email=%, waitlist_id=%, member_id=%, is_active=%, waitlist_status=%', 
        v_email, v_waitlist_id, v_member_id, v_is_active, v_waitlist_status;

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
    elsif v_waitlist_status not in ('completed', 'invited') then
        raise exception using
            errcode = 'U0007',
            message = 'This user has not completed the workshop.',
            hint = 'Waitlist status: ' || v_waitlist_status;
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
