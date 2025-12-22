-- Drop the update_member_data stored procedure
-- This function is now replaced by Kysely queries in MemberService._updateWithArgs
DROP FUNCTION IF EXISTS public.update_member_data(
    UUID,
    TEXT,
    TEXT,
    BOOLEAN,
    TEXT,
    TEXT,
    public.gender,
    TEXT,
    DATE,
    TEXT,
    TEXT,
    public.preferred_weapon[],
    TIMESTAMP WITH TIME ZONE,
    TIMESTAMP WITH TIME ZONE,
    TIMESTAMP WITH TIME ZONE,
    BOOLEAN,
    JSONB,
    public.social_media_consent
);
