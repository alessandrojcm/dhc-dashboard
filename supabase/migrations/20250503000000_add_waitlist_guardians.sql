-- `waitlist_guardians` – one row per guardian, linked to a waitlist entry
CREATE TABLE public.waitlist_guardians (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    profile_id    uuid NOT NULL REFERENCES public.member_profiles(id) ON DELETE CASCADE,
    first_name     text NOT NULL,
    last_name      text NOT NULL,
    phone_number   text NOT NULL,
    created_at     timestamptz DEFAULT now()
);

-- (Optional) helper index if we are going to query by waitlist_id often
CREATE INDEX ON public.waitlist_guardians(profile_id);