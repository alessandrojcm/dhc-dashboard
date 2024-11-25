-- Create enum for waitlist status
create type waitlist_status as enum (
    'waiting', -- Initial state
    'invited', -- Selected for workshop
    'paid', -- Payment received
    'deferred', -- Requested postponement
    'cancelled', -- Cancelled their request
    'completed', -- Completed workshop
    'no_reply' -- Did not reply to message
    );

-- Create waitlist table
create table waitlist
(
    id                        uuid                     default gen_random_uuid() primary key,
    -- Personal Information
    first_name                text            not null,
    last_name                 text            not null,
    email                     text            not null unique,
    phone_number              text            not null,
    date_of_birth             date            not null,
    -- Medical and Insurance
    medical_conditions        text,
    insurance_form_submitted  boolean                  default false,
    -- Status Management
    status                    waitlist_status not null default 'waiting',
    initial_registration_date timestamp with time zone default now(),
    -- Tracking
    last_status_change        timestamp with time zone default now(),
    last_contacted            timestamp with time zone,
    -- Notes
    admin_notes               text,
    -- Constraints
    constraint unique_email unique (email),
    constraint future_birth_date check (extract(year from date_of_birth) >= 16 and date_of_birth < current_date)
);

alter table waitlist
    enable row level security;

-- Status history tracking
create table waitlist_status_history
(
    id          uuid                     default uuid_generate_v4() primary key,
    waitlist_id uuid references waitlist (id),
    old_status  waitlist_status,
    new_status  waitlist_status not null,
    changed_at  timestamp with time zone default now(),
    changed_by  uuid references auth.users (id),
    notes       text
);

-- Function to update waitlist status
create or replace function update_waitlist_status(
    p_waitlist_id uuid,
    p_new_status waitlist_status,
    p_notes text default null
)
    returns void as
$$
declare
    v_old_status waitlist_status;
begin
    -- Get current status
    select status
    into v_old_status
    from waitlist
    where id = p_waitlist_id;

    -- Update status and last_status_change
    update waitlist
    set status             = p_new_status,
        last_status_change = now()
    where id = p_waitlist_id;

    -- Record in history
    insert into waitlist_status_history
        (waitlist_id, old_status, new_status, changed_by, notes)
    values (p_waitlist_id, v_old_status, p_new_status, auth.uid(), p_notes);
end;
$$ language plpgsql security invoker;

-- Function to get position in waitlist
create or replace function get_waitlist_position(p_waitlist_id uuid)
    returns integer as
$$
begin
    return (select position
            from (select id,
                         row_number() over (
                             order by
                                 initial_registration_date
                             ) as position
                  from waitlist
                  where status = 'waiting') as positions
            where id = p_waitlist_id);
end;
$$ language plpgsql security invoker;

-- RLS Policies

-- Only committee members, coaches, and admins can view waitlist
create policy "Committee and coaches can view waitlist"
    on waitlist for select
    to authenticated
    using (
    has_any_role((select auth.uid()), array ['admin', 'president', 'committee_coordinator',
        'beginners_coordinator', 'coach']::role_type[])
    );

-- Only workshop coordinators and admins can modify waitlist
create policy "Workshop coordinators can modify waitlist"
    on waitlist for all
    to authenticated
    using (
    has_any_role((select auth.uid()), array ['admin', 'president', 'beginners_coordinator']::role_type[])
    );

create policy "Only committee members can view the waitlist history"
    on waitlist_status_history
    for all
    to authenticated
    using (
    has_any_role((select auth.uid()), array ['admin', 'president', 'beginners_coordinator']::role_type[])
    );

-- Indexes for performance
create index idx_waitlist_status on waitlist (status);
create index idx_waitlist_registration_date on waitlist (initial_registration_date);
create index idx_waitlist_email on waitlist (email);
create index idx_waitlist_names on waitlist (last_name, first_name);

-- Helper view for waitlist management
create view waitlist_management_view as
select w.*,
       concat(w.first_name, ' ', w.last_name)  as full_name,
       get_waitlist_position(w.id)             as current_position,
       extract(year from age(w.date_of_birth)) as age,
       case
           when w.status = 'waiting' and
                not exists (select 1
                            from waitlist_status_history
                            where waitlist_id = w.id
                              and new_status = 'invited')
               then true
           else false
           end                                 as never_invited
from waitlist w;

-- Trigger to maintain last_status_change
create or replace function update_last_status_change()
    returns trigger as
$$
begin
    if OLD.status != NEW.status then
        NEW.last_status_change := current_timestamp;
    end if;
    return NEW;
end;
$$ language plpgsql;

create trigger waitlist_status_change
    before update
    on waitlist
    for each row
execute function update_last_status_change();
