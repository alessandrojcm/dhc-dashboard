-- Create enum types for statuses
create type workshop_status as enum ('draft', 'published', 'finished', 'cancelled');
create type workshop_attendee_status as enum ('invited', 'confirmed', 'attended', 'no_show', 'cancelled');

-- Create workshops table
create table workshops
(
    id               uuid primary key                  default gen_random_uuid(),
    status           workshop_status not null          default 'draft',
    workshop_date    timestamptz     not null,
    location         text            not null,
    coach_id         uuid references user_profiles (id),
    capacity         integer         not null          default 16,
    cool_off_days    integer         not null          default 5,
    batch_size       integer         not null          default 16,
    stripe_price_key text,
    notes_md         text,
    created_at       timestamptz     not null          default now(),
    updated_at       timestamptz     not null          default now()
);
create index on workshops (status);
create index on workshops (coach_id);

-- Create workshop_assistants table
create table workshop_assistants
(
    workshop_id uuid not null references workshops (id) on delete cascade,
    member_id   uuid not null references user_profiles (id) on delete cascade,
    primary key (workshop_id, member_id)
);
create index on workshop_assistants (member_id);

-- Create workshop_attendees table
create table workshop_attendees
(
    id               uuid primary key                  default gen_random_uuid(),
    workshop_id      uuid        not null references workshops (id) on delete cascade,
    user_profile_id  uuid        not null references user_profiles (id) on delete cascade,
    status           workshop_attendee_status not null default 'invited',
    priority         integer     not null               default 0,
    invited_at       timestamptz,
    payment_url_token      text,
    paid_at          timestamptz,
    checkin_token    text,
    checked_in_at    timestamptz,
    consent_media_at timestamptz,
    insurance_ok_at  timestamptz,
    signature_url    text,
    refunded_at      timestamptz,
    credit_used_at   timestamptz,
    unique (workshop_id, user_profile_id)
);
create index on workshop_attendees (workshop_id);
create index on workshop_attendees (user_profile_id);
create index on workshop_attendees (status);


-- RLS for workshops
alter table workshops
    enable row level security;
create policy "Admins and coaches can manage workshops" on workshops for all
    using (has_any_role((select auth.uid()), array ['admin', 'president', 'coach', 'beginners_coordinator']::role_type[]));
create policy "Authenticated users can view published workshops" on workshops for select
    using (status = 'published');

-- RLS for workshop_assistants
alter table workshop_assistants
    enable row level security;
create policy "Admins and coaches can manage assistants" on workshop_assistants for all
    using (has_any_role((select auth.uid()), array ['admin', 'president', 'coach', 'beginners_coordinator']::role_type[]));
create policy "Assistants can see their own assignment" on workshop_assistants for select
    using ((select supabase_user_id from user_profiles where id = member_id) = (select auth.uid()));

-- RLS for workshop_attendees
alter table workshop_attendees
    enable row level security;
create policy "Admins and coaches can manage attendees" on workshop_attendees for all
    using (has_any_role((select auth.uid()), array ['admin', 'president', 'coach', 'beginners_coordinator']::role_type[]));

create policy "Attendees can see their own records" on workshop_attendees for select
    using ((select supabase_user_id from user_profiles where id = user_profile_id) = (select auth.uid()));

create policy "Attendees can update their record with a checkin token" on workshop_attendees for update
    using (checkin_token is not null and checkin_token = current_setting('request.headers.x-checkin-token', true))
    with check (checkin_token is not null and checkin_token = current_setting('request.headers.x-checkin-token', true));

-- Function to update the updated_at column
create or replace function set_updated_at()
    returns trigger as
$$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

create trigger workshops_updated_at
    before update
    on workshops
    for each row
execute procedure set_updated_at();

-- The CHECK constraint was incorrect as payment_url_token is a token, not a full URL.
-- ALTER TABLE workshop_attendees
-- ADD CONSTRAINT payment_url_token_is_url
-- CHECK (payment_url_token ~ '^https?://');
