-- Add search vector column
ALTER TABLE waitlist
    ADD COLUMN search_text tsvector
        GENERATED ALWAYS AS (
            setweight(to_tsvector('english', coalesce(first_name, '')), 'A') ||
            setweight(to_tsvector('english', coalesce(last_name, '')), 'A') ||
            setweight(to_tsvector('english', coalesce(email, '')), 'B')
            ) STORED;

drop view waitlist_management_view;
create view waitlist_management_view as
select w.*,
       concat(w.first_name, ' ', w.last_name)  as full_name,
       get_waitlist_position(w.id)             as current_position,
       extract(year from age(w.date_of_birth)) as age
from waitlist w;


-- Create GIN index for faster searching
CREATE INDEX waitlist_search_idx ON waitlist USING GIN (search_text);

-- Drop existing constraint if it exists
ALTER TABLE waitlist
    DROP CONSTRAINT IF EXISTS future_birth_date;

-- Add new age constraint
ALTER TABLE waitlist
    ADD CONSTRAINT future_birth_date
        CHECK (
            date_of_birth < current_date AND
            extract(year from age(current_date, date_of_birth)) >= 16
            );
