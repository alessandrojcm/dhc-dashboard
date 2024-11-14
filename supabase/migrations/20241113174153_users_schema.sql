-- Enable required extensions
create extension if not exists "uuid-ossp";

/*
 * Role types enum
 */
create type role_type as enum (
    -- Super user roles
    'admin',
    'president',
    -- Committee roles
    'treasurer',
    'committee_coordinator',
    'sparring_coordinator',
    'workshop_coordinator',
    'beginners_coordinator',
    'quartermaster',
    'pr_manager',
    'volunteer_coordinator',
    'research_coordinator'
    );

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
    roles            role_type[] not null     default '{}'::role_type[],
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

/*
 * Role checking functions
 */
-- Check if user has specific role
create or replace function has_role(user_id uuid, required_role role_type)
    returns boolean as
$$
begin
    return exists (select 1
                   from user_profiles
                   where user_profiles.id = user_id
                     and (
                       required_role = any (roles)
                           or 'admin'::role_type = any (roles)
                           or 'president'::role_type = any (roles)
                       ));
end;
$$ language plpgsql security definer;

-- Check if user has any of the specified roles
create or replace function has_any_role(user_id uuid, required_roles role_type[])
    returns boolean as
$$
begin
    return exists (select 1
                   from user_profiles
                   where user_profiles.id = user_id
                     and (
                       roles && required_roles
                           or 'admin'::role_type = any (roles)
                           or 'president'::role_type = any (roles)
                       ));
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

-- Log role changes
create or replace function log_role_change()
    returns trigger as
$$
begin
    if old.roles is distinct from new.roles then
        insert into user_audit_log (user_id, action, details)
        values (new.id,
                'role_update',
                jsonb_build_object(
                        'old_roles', old.roles,
                        'new_roles', new.roles,
                        'modified_by', auth.uid()
                ));
    end if;
    return new;
end;
$$ language plpgsql security definer;

create trigger log_role_changes
    after update
    on user_profiles
    for each row
    when (old.roles is distinct from new.roles)
execute function log_role_change();

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
    for select using (
    is_active = true
        and is_allowed_login()
    );

create policy "Users can update their own basic info"
    on user_profiles
    for update using (id = auth.uid())
    with check (id = auth.uid());

create policy "Committee coordinators can manage roles"
    on user_profiles
    for update using (
    has_any_role(auth.uid(), array ['committee_coordinator', 'president', 'admin']::role_type[])
    )
    with check (
    has_any_role(auth.uid(), array ['committee_coordinator', 'president', 'admin']::role_type[])
    );

-- Audit log policies
create policy "Audit logs viewable by admins"
    on user_audit_log
    for select using (
    has_any_role(auth.uid(), array ['admin', 'president', 'committee_coordinator']::role_type[])
    );

/*
 * Indexes
 */
create index idx_user_profiles_email on user_profiles (email);
create index idx_user_profiles_discord_id on user_profiles (discord_id);
create index idx_user_audit_created_at on user_audit_log (created_at);
create index idx_user_profiles_roles on user_profiles using gin (roles);
