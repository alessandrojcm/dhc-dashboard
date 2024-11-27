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
end;
$$
