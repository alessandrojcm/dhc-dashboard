ALTER TABLE user_profiles
    ADD COLUMN date_of_birth date not null,
    ADD CONSTRAINT dob_age_check CHECK (
        date_of_birth < current_date AND
        extract(year from age(current_date, date_of_birth)) >= 16
        );
