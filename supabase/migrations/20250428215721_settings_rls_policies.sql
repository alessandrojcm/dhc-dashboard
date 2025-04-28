-- Add RLS policy for settings table to allow specific roles to write
-- This migration adds policy for admin, president, and committee_coordinator roles

-- Create policy for committee members to modify settings
CREATE POLICY "Committee members can modify settings" ON settings FOR 
UPDATE TO authenticated USING (
    (
        SELECT has_any_role(
                (
                    SELECT auth.uid()
                ),
                ARRAY ['admin', 'president', 'committee_coordinator']::role_type []
            )
    )
)
WITH CHECK (
    (
        SELECT has_any_role(
                (
                    SELECT auth.uid()
                ),
                ARRAY ['admin', 'president', 'committee_coordinator']::role_type []
            )
    )
);

-- Create policy for committee members to insert settings
CREATE POLICY "Committee members can insert settings" ON settings FOR 
INSERT TO authenticated WITH CHECK (
    (
        SELECT has_any_role(
                (
                    SELECT auth.uid()
                ),
                ARRAY ['admin', 'president', 'committee_coordinator']::role_type []
            )
    )
);

-- Create policy for committee members to delete settings
CREATE POLICY "Committee members can delete settings" ON settings FOR 
DELETE TO authenticated USING (
    (
        SELECT has_any_role(
                (
                    SELECT auth.uid()
                ),
                ARRAY ['admin', 'president', 'committee_coordinator']::role_type []
            )
    )
);

-- Add comment to explain the purpose of these policies
COMMENT ON TABLE settings IS 'System settings with RLS policies allowing read access to all authenticated users and write access to admin, president, and committee_coordinator roles';
