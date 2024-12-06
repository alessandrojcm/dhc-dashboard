create or replace function get_current_user_with_profile() returns jsonb
    language plpgsql
    set search_path = public as
$$
declare
    curr_id text;
begin
    select auth.uid() into curr_id;
    return (select jsonb_build_object(
                   'firstName', public.user_profiles.first_name,
                   'lastName', public.user_profiles.last_name,
                   'roles', array_agg(public.user_roles.role)
           )
    from public.user_profiles
             left join public.user_roles on public.user_profiles.supabase_user_id = public.user_roles.user_id
    where public.user_profiles.supabase_user_id = curr_id::uuid
    group by public.user_profiles.first_name, public.user_profiles.last_name);
end;
$$;


grant execute on function get_current_user_with_profile
    to authenticated;

revoke all on function get_current_user_with_profile
    from anon;
