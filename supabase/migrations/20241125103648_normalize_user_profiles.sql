drop view waitlist_management_view;

drop index idx_waitlist_email;
drop index idx_waitlist_names;

alter table user_profiles
    add column
        phone_number text not null default '';

alter table waitlist
    drop search_text;

alter table waitlist
    drop column gender;

alter table waitlist
    drop column pronouns;

alter table waitlist
    drop column first_name;

alter table waitlist
    drop column last_name;

alter table waitlist
    drop column date_of_birth;

alter table user_profiles
    add column waitlist_id uuid;

alter table waitlist
    drop column phone_number;

alter table user_profiles
    add constraint fk_waitlist_id foreign key (waitlist_id) references waitlist (id) on delete cascade;

ALTER TABLE user_profiles
    ADD COLUMN search_text tsvector
        GENERATED ALWAYS AS (
            setweight(to_tsvector('english', coalesce(first_name, '')), 'A') ||
            setweight(to_tsvector('english', coalesce(last_name, '')), 'A')
            ) STORED;

create index idx_waitlist_user_profile on user_profiles (waitlist_id);
create index idx_user_profiles_names on user_profiles (first_name, last_name);
create index idx_waitlist_concat_info on user_profiles (first_name, last_name, waitlist_id);
create view waitlist_management_view as
select w.*,
       u.search_text                           as search_text,
       u.phone_number                          as phone_number,
       u.medical_conditions                    as medical_conditions,
       concat(u.first_name, ' ', u.last_name)  as full_name,
       get_waitlist_position(w.id)             as current_position,
       extract(year from age(u.date_of_birth)) as age
from user_profiles u
         join waitlist w on u.waitlist_id = w.id
where u.waitlist_id is not null;

create or replace function insert_waitlist_entry(
    first_name text,
    last_name text,
    email text,
    date_of_birth timestamptz,
    phone_number text,
    pronouns text,
    gender public.gender,
    medical_conditions text
)
    returns table
            (
                profile_id              uuid,
                waitlist_id             uuid,
                user_first_name         text,
                user_last_name          text,
                user_email              text,
                user_date_of_birth      date,
                user_phone_number       text,
                user_pronouns           text,
                user_gender             public.gender,
                user_medical_conditions text
            )
    language plpgsql
    set search_path = ''
as
$$
declare
    new_waitlist_id uuid;
begin
    begin
        insert into public.waitlist (email)
        values (email)
        returning id into new_waitlist_id;

        insert into public.user_profiles (first_name, last_name, date_of_birth, phone_number, pronouns, gender,
                                          is_active, waitlist_id, medical_conditions)
        values (first_name,
                last_name,
                date_of_birth,
                phone_number,
                pronouns,
                gender,
                false,
                new_waitlist_id,
                medical_conditions);

        RETURN QUERY
            SELECT u.id                 AS profile_id,
                   w.id                 AS waitlist_id,
                   u.first_name         AS user_first_name,
                   u.last_name          AS user_last_name,
                   w.email              AS user_email,
                   u.date_of_birth      AS user_date_of_birth,
                   u.phone_number       AS user_phone_number,
                   u.pronouns           AS user_pronouns,
                   u.gender             AS user_gender,
                   u.medical_conditions AS user_medical_conditions
            FROM public.waitlist w
                     JOIN public.user_profiles u ON w.id = u.waitlist_id
            WHERE w.id = new_waitlist_id;
    exception
        when others then
            raise;
    end;
end;
$$;


ALTER FUNCTION insert_waitlist_entry(
    text, text, text, timestamp with time zone, text, text, gender, text
    ) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION insert_waitlist_entry(
    text, text, text, timestamp with time zone, text, text, gender, text
    ) TO service_role;
