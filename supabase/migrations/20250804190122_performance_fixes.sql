-- Optimize club_activities RLS policies by combining into single policy
DROP POLICY "Users can see workshops" ON public.club_activities;
DROP POLICY "Workshop coordinators can manage activities" ON public.club_activities;

-- Create single optimized policy for club_activities
CREATE POLICY "club_activities_access_policy" ON public.club_activities
FOR ALL
TO authenticated
USING (
  CASE 
    WHEN has_any_role((select auth.uid()), ARRAY['workshop_coordinator', 'president', 'admin']::role_type[]) 
    THEN true
    WHEN has_any_role((select auth.uid()), ARRAY['member']::role_type[]) 
    THEN true
    ELSE false
  END
)
WITH CHECK (
  has_any_role((select auth.uid()), ARRAY['workshop_coordinator', 'president', 'admin']::role_type[])
);

-- Optimize club_activity_interest RLS policies by combining into single policy
DROP POLICY "Coordinators can view all interests" ON public.club_activity_interest;
DROP POLICY "Users can express interest for themselves" ON public.club_activity_interest;
DROP POLICY "Users can view their own interests" ON public.club_activity_interest;
DROP POLICY "Users can withdraw their own interest" ON public.club_activity_interest;

-- Create single optimized policy for club_activity_interest
CREATE POLICY "club_activity_interest_access_policy" ON public.club_activity_interest
FOR ALL
TO authenticated
USING (
  -- Coordinators can see all records, users can see their own
  has_any_role((select auth.uid()), ARRAY['workshop_coordinator', 'president', 'admin']::role_type[])
  OR user_id = (select auth.uid())
)
WITH CHECK (
  -- Users can only create/modify their own records
  user_id = (select auth.uid())
);

-- Optimize club_activity_refunds RLS policies by combining into single policy
DROP POLICY "Committee can manage refunds" ON public.club_activity_refunds;
DROP POLICY "Committee can view all refunds" ON public.club_activity_refunds;
DROP POLICY "Members can view own refunds" ON public.club_activity_refunds;

-- Create single optimized policy for club_activity_refunds
CREATE POLICY "club_activity_refunds_access_policy" ON public.club_activity_refunds
FOR ALL
TO authenticated
USING (
  -- Committee can see all refunds, members can see their own
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'workshop_coordinator']::role_type[])
  OR EXISTS (
    SELECT 1
    FROM club_activity_registrations car
    WHERE car.id = club_activity_refunds.registration_id 
    AND car.member_user_id = (select auth.uid())
  )
)
WITH CHECK (
  -- Only committee can create/modify refunds
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'workshop_coordinator']::role_type[])
);

-- Optimize club_activity_registrations RLS policies by combining into single policy
DROP POLICY "Committee can view all registrations" ON public.club_activity_registrations;
DROP POLICY "Members can view own registrations" ON public.club_activity_registrations;
DROP POLICY "Users can insert own registrations" ON public.club_activity_registrations;
DROP POLICY "Users can update own registrations" ON public.club_activity_registrations;

-- Create single optimized policy for club_activity_registrations
CREATE POLICY "club_activity_registrations_access_policy" ON public.club_activity_registrations
FOR ALL
TO authenticated
USING (
  -- Committee can see all registrations, members can see their own
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'beginners_coordinator']::role_type[])
  OR member_user_id = (select auth.uid())
)
WITH CHECK (
  -- Users can create their own or external registrations, committee can update any
  (member_user_id = (select auth.uid()) OR (member_user_id IS NULL AND external_user_id IS NOT NULL))
  OR has_any_role((select auth.uid()), ARRAY['admin', 'president', 'beginners_coordinator']::role_type[])
);

-- Optimize invitations RLS policies by combining into single policy
DROP POLICY "Admins can create and update invitations" ON public.invitations;
DROP POLICY "Admins can see all invitations" ON public.invitations;
DROP POLICY "Users can see their own invitations" ON public.invitations;

-- Create single optimized policy for invitations
CREATE POLICY "invitations_access_policy" ON public.invitations
FOR ALL
TO authenticated
USING (
  -- Admins can see all invitations, users can see their own
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[])
  OR user_id = (select auth.uid())
)
WITH CHECK (
  -- Only admins can create/modify invitations
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[])
);

-- Optimize member_profiles RLS policies by combining into single policy
DROP POLICY "Committee members can view all profiles" ON public.member_profiles;
DROP POLICY "Members can view their own profile" ON public.member_profiles;

-- Create single optimized policy for member_profiles
CREATE POLICY "member_profiles_access_policy" ON public.member_profiles
FOR SELECT
TO authenticated
USING (
  -- Committee members can see all profiles, members can see their own
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'treasurer', 'committee_coordinator', 'sparring_coordinator', 'workshop_coordinator', 'beginners_coordinator', 'quartermaster', 'pr_manager', 'volunteer_coordinator', 'research_coordinator', 'coach']::role_type[])
  OR id = (select auth.uid())
);

-- Optimize user_profiles RLS policies by combining into single policy (keep auth admin separate)
DROP POLICY "Commitee members can create users" ON public.user_profiles;
DROP POLICY "Committee members can see all profiles" ON public.user_profiles;
DROP POLICY "Users can view their own profile" ON public.user_profiles;

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
  has_any_role((select auth.uid()), ARRAY['admin', 'president', 'committee_coordinator']::role_type[])
);
