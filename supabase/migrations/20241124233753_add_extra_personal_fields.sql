CREATE TYPE gender AS ENUM (
    'man (cis)',
    'woman (cis)',
    'non-binary',
    'man (trans)',
    'woman (trans)',
    'other'
    );

ALTER TABLE user_roles
    ADD COLUMN gender gender;

ALTER TABLE user_roles
    ADD COLUMN pronouns text;

ALTER TABLE waitlist
    ADD COLUMN gender gender;

ALTER TABLE waitlist
    ADD COLUMN pronouns text;

create or replace function get_gender_options()
    returns json
    language plpgsql
as
$$
DECLARE
    options json;
begin
    select json_agg(enumlabel) as gender_options
    into options
    from pg_enum
    where enumtypid = 'gender'::regtype;
    return options;
end;
$$;
