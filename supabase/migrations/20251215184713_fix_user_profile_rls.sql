DROP POLICY "user_profiles_access_policy" ON public.user_profiles;

-- Create single optimized policy for user_profiles (authenticated users)
CREATE POLICY "user_profiles_access_policy" ON public.user_profiles
FOR ALL
TO authenticated
USING (
  -- Committee can see all profiles, users can see their own active profile
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'treasurer', 'committee_coordinator', 'sparring_coordinator', 'workshop_coordinator', 'beginners_coordinator', 'quartermaster', 'pr_manager', 'volunteer_coordinator', 'research_coordinator']::role_type[])
  OR (supabase_user_id = (select auth.uid()) AND is_active = true)
)
WITH CHECK (
  -- Only committee can create/modify user profiles
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[]) OR (supabase_user_id = (select auth.uid()) AND is_active = true)
);
