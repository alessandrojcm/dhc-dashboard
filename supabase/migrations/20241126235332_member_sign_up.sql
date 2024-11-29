-- Parameters:
--   uid - The UUID of the user to check
-- Returns:
--   JSONB containing either user information or an error object
--   Success: {'first_name': string, 'last_name': string, ...}
--   Error: {'error': {'http_code': number, 'message': string}}
create or replace function get_membership_info(uid uuid)
    returns jsonb
    language plpgsql
    stable
    set search_path = ''
as
$$
begin
    if uid is null then
        return jsonb_build_object(
            'error', jsonb_build_object(
                'http_code', 400,
                'message', 'User ID cannot be null.'
            )
        );
    end if;

    return (
        with base_check as (
            select 
                case 
                    when not exists (select 1 from auth.users where id = uid) then
                        jsonb_build_object(
                            'error', jsonb_build_object(
                                'http_code', 403,
                                'message', 'User not found.'
                            )
                        )
                end as result
        ),
        user_check as (
            select u.id, u.email, u.banned_until
            from auth.users u
            where u.id = uid
        ),
        waitlist_check as (
            select w.id as waitlist_id, w.email
            from user_check uc
            left join public.waitlist w on w.email = uc.email
        ),
        profile_info as (
            select 
                   case
                       when uc.banned_until > now() then
                           jsonb_build_object(
                               'error', jsonb_build_object(
                                   'http_code', 403,
                                   'message', 'User is banned.'
                               )
                           )
                       when wc.waitlist_id is null then
                           jsonb_build_object(
                               'error', jsonb_build_object(
                                   'http_code', 404,
                                   'message', 'Waitlist entry not found.'
                               )
                           )
                       when mp.id is not null then
                           jsonb_build_object(
                               'error', jsonb_build_object(
                                   'http_code', 400,
                                   'message', 'User already active.'
                               )
                           )
                       else
                           jsonb_build_object(
                               'first_name', up.first_name,
                               'last_name', up.last_name,
                               'phone_number', up.phone_number,
                               'date_of_birth', up.date_of_birth,
                               'pronouns', up.pronouns,
                               'gender', up.gender
                           )
                   end as result
            from user_check uc
            left join waitlist_check wc on wc.email = uc.email
            left join public.user_profiles up on up.waitlist_id = wc.waitlist_id
            left join public.member_profiles mp on mp.user_profile_id = up.id
        )
        select coalesce(
            (select result from base_check where result is not null),
            (select result from profile_info)
        )
    );
end
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
    preferred_weapon public.preferred_weapon,
    additional_data jsonb default '{}'::jsonb
)
    returns jsonb
    language plpgsql
    security definer
    set search_path = ''
as
$$
declare
    v_user_profile_id uuid;
    v_member_id uuid;
    v_membership_info jsonb;
begin
    -- Get membership eligibility info
    v_membership_info := public.get_membership_info(uid);
    
    -- Check for errors in membership info
    if (v_membership_info->>'error') is not null then
        return v_membership_info;
    end if;

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
        return jsonb_build_object(
            'error', jsonb_build_object(
                'http_code', 404,
                'message', 'User profile not found.'
            )
        );
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
            'preferred_weapon', preferred_weapon
        ),
        'message', 'Pending member created successfully. Membership will be activated upon payment confirmation.'
    );

exception
    when unique_violation then
        return jsonb_build_object(
            'error', jsonb_build_object(
                'http_code', 409,
                'message', 'Member profile already exists.'
            )
        );
    when others then
        return jsonb_build_object(
            'error', jsonb_build_object(
                'http_code', 500,
                'message', 'An unexpected error occurred: ' || SQLERRM
            )
        );
end;
$$;
