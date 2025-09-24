DROP POLICY IF EXISTS "Committee can view all registrations" ON club_activity_registrations;

DROP POLICY IF EXISTS "Users can update own registrations" ON club_activity_registrations;

CREATE POLICY "Committee can view all registrations" ON club_activity_registrations
    FOR SELECT USING (
    has_any_role((select auth.uid()), ARRAY ['admin', 'president', 'workshop_coordinator']::role_type[])
    );

CREATE POLICY "Users can update own registrations" ON club_activity_registrations
    FOR UPDATE USING (
    member_user_id = (select auth.uid()) OR
    has_any_role((select auth.uid()), ARRAY ['admin', 'president', 'workshop_coordinator']::role_type[])
    );
