-- Enable required extensions
create extension if not exists "uuid-ossp";

-- Create database roles
do
$$
    begin
        -- Super user roles
        execute 'create role dhc_admin';
        execute 'create role dhc_president';

        -- Committee roles
        execute 'create role dhc_treasurer';
        execute 'create role dhc_committee_coordinator';
        execute 'create role dhc_sparring_coordinator';
        execute 'create role dhc_workshop_coordinator';
        execute 'create role dhc_beginners_coordinator';
        execute 'create role dhc_quartermaster';
        execute 'create role dhc_pr_manager';
        execute 'create role dhc_volunteer_coordinator';
        execute 'create role dhc_research_coordinator';

        -- Base authenticated role (all logged in users)
        execute 'create role dhc_authenticated';
    end
$$;

-- Grant role hierarchies
-- Grant authenticated privileges to ALL committee roles
grant dhc_authenticated to
    dhc_admin,
    dhc_president,
    dhc_treasurer,
    dhc_committee_coordinator,
    dhc_sparring_coordinator,
    dhc_workshop_coordinator,
    dhc_beginners_coordinator,
    dhc_quartermaster,
    dhc_pr_manager,
    dhc_volunteer_coordinator,
    dhc_research_coordinator;

/*
 * Core tables
 */
-- User profiles
create table user_profiles
(
    id               uuid references auth.users (id) primary key,
    email            text unique not null,
    full_name        text        not null,
    discord_id       text unique,
    discord_username text,
    is_active        boolean                  default true,
    last_login       timestamp with time zone,
    created_at       timestamp with time zone default now(),
    updated_at       timestamp with time zone default now()
);

-- Audit log
create table user_audit_log
(
    id         uuid                     default uuid_generate_v4() primary key,
    user_id    uuid references auth.users (id),
    action     text not null,
    details    jsonb,
    ip_address text,
    created_at timestamp with time zone default now()
);

/*
 * Authentication functions
 */
-- Check if discord login is allowed
create or replace function is_allowed_login()
    returns boolean as
$$
declare
    discord_id text;
begin
    -- Get the user's discord id from auth.jwt()
    discord_id := (select raw_user_meta_data ->> 'discord_id' from auth.users where id = auth.uid());

    -- Check if user exists in user_profiles and is active
    return exists (select 1
                   from user_profiles
                   where discord_id = discord_id
                     and is_active = true);
end;
$$ language plpgsql security definer;

-- Function to get user's database role from auth.users
create or replace function get_user_role()
    returns text as $$
begin
    return (
        select role
        from auth.users
        where id = auth.uid()
    );
end;
$$ language plpgsql security definer;

-- Check if current user has a specific role
create or replace function has_role(role_name text)
    returns boolean as $$
begin
    return (
        select exists (
            select 1
            from pg_roles
            where pg_has_role(get_user_role(), oid, 'member')
              and rolname = role_name
        )
    );
end;
$$ language plpgsql security definer;

/*
 * Triggers
 */
-- Update updated_at timestamp
create or replace function update_updated_at_column()
    returns trigger as
$$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

create trigger update_user_profiles_updated_at
    before update
    on user_profiles
    for each row
execute function update_updated_at_column();

/*
 * RLS Policies
 */
-- Enable RLS
alter table user_profiles
    enable row level security;
alter table user_audit_log
    enable row level security;
alter table auth.users
    enable row level security;

-- Auth policies
create policy "Only allowed users can sign in"
    on auth.users
    for select
    using (
    is_allowed_login()
    );

-- User profile policies
create policy "Users can view all active profiles"
    on user_profiles
    for select
    using (
    is_active = true
        and is_allowed_login()
    );

create policy "Users can update their own basic info"
    on user_profiles
    for update
    using (id = auth.uid())
    with check (id = auth.uid());

create policy "Admins can manage all profiles"
    on user_profiles
    for all
    using (
    has_role('dhc_admin') or has_role('dhc_president')
    );

-- Audit log policies
create policy "Audit logs viewable by admins"
    on user_audit_log
    for select
    using (
    has_role('dhc_admin')
    );

-- Grant access to roles
grant select on user_profiles to dhc_authenticated;
grant update on user_profiles to dhc_authenticated;
grant all on user_profiles to dhc_admin;
grant select on user_audit_log to dhc_admin;

/*
 * Indexes
 */
create index idx_user_profiles_email on user_profiles (email);
create index idx_user_profiles_discord_id on user_profiles (discord_id);
create index idx_user_audit_created_at on user_audit_log (created_at);
