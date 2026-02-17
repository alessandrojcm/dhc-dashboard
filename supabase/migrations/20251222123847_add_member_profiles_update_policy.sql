-- Add UPDATE policy for member_profiles table
-- Previously, updates were done via SECURITY DEFINER stored procedures which bypassed RLS
-- Now that we use direct Kysely queries, we need proper UPDATE policies

-- Members can update their own profile
CREATE POLICY "Members can update their own profile"
    ON public.member_profiles FOR UPDATE
    TO authenticated
    USING (
        (SELECT auth.uid()) = public.member_profiles.id
    )
    WITH CHECK (
        (SELECT auth.uid()) = public.member_profiles.id
    );

-- Committee members can update all profiles
CREATE POLICY "Committee members can update all profiles"
    ON public.member_profiles FOR UPDATE
    TO authenticated
    USING (
        (SELECT public.has_any_role(
            (SELECT auth.uid()),
            ARRAY ['admin', 'president', 'treasurer', 'committee_coordinator']::public.role_type[]
        ))
    )
    WITH CHECK (
        (SELECT public.has_any_role(
            (SELECT auth.uid()),
            ARRAY ['admin', 'president', 'treasurer', 'committee_coordinator']::public.role_type[]
        ))
    );
