ALTER TABLE public.waitlist_guardians ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Committee members can see guardians" ON public.waitlist_guardians FOR
    ALL TO authenticated USING (
    (SELECT has_any_role(
                    (SELECT auth.uid()),
                    ARRAY ['admin', 'president', 'treasurer', 'committee_coordinator', 'sparring_coordinator', 'workshop_coordinator', 'beginners_coordinator', 'quartermaster', 'pr_manager', 'volunteer_coordinator', 'research_coordinator', 'coach']::role_type[]
            ) or ((select auth.uid()) =
                  (select user_profiles.supabase_user_id from user_profiles where id = waitlist_guardians.profile_id)))
    );