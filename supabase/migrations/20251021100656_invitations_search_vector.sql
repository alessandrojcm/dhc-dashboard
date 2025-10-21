ALTER TABLE public.invitations
    ADD COLUMN search_text tsvector
        GENERATED ALWAYS AS (
            setweight(to_tsvector('english', coalesce(email, '')), 'B')
            ) STORED;
