-- Create club_activity_interest table
CREATE TABLE club_activity_interest
(
    id               UUID PRIMARY KEY         DEFAULT gen_random_uuid(),
    club_activity_id UUID NOT NULL REFERENCES club_activities (id) ON DELETE CASCADE,
    user_id          UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at       TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at       TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Prevent duplicate interest per user/workshop
    UNIQUE (club_activity_id, user_id)
);

-- Add indexes for performance
CREATE INDEX idx_club_activity_interest_activity_id ON club_activity_interest (club_activity_id);
CREATE INDEX idx_club_activity_interest_user_id ON club_activity_interest (user_id);
CREATE INDEX idx_club_activity_interest_created_at ON club_activity_interest (created_at);

-- Enable RLS
ALTER TABLE club_activity_interest
    ENABLE ROW LEVEL SECURITY;

-- RLS Policies
-- Users can only see their own interests
CREATE POLICY "Users can view their own interests"
    ON club_activity_interest
    FOR SELECT
    TO authenticated
    USING (
    user_id = (SELECT auth.uid())
    );

-- Users can express interest for themselves
CREATE POLICY "Users can express interest for themselves"
    ON club_activity_interest
    FOR INSERT
    TO authenticated
    WITH CHECK (
    user_id = (SELECT auth.uid())
    );

-- Users can withdraw their own interest
CREATE POLICY "Users can withdraw their own interest"
    ON club_activity_interest
    FOR DELETE
    TO authenticated
    USING (
    user_id = (SELECT auth.uid())
    );

-- Coordinators can view all interests for workshop management
CREATE POLICY "Coordinators can view all interests"
    ON club_activity_interest
    FOR SELECT
    TO authenticated
    USING (
    has_any_role(
            (SELECT auth.uid()),
            ARRAY ['workshop_coordinator', 'president', 'admin']::role_type[]
    )
    );

CREATE POLICY "Users can see workshops"
    ON club_activities
    FOR SELECT
    TO authenticated
    USING (
    has_any_role((SELECT auth.uid()), ARRAY ['member']::role_type[])
    );

-- Add trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
    RETURNS TRIGGER AS
$$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_club_activity_interest_updated_at
    BEFORE UPDATE
    ON club_activity_interest
    FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Create interest count view for performance
CREATE VIEW club_activity_interest_counts AS
SELECT club_activity_id,
       COUNT(*) as interest_count
FROM club_activity_interest
GROUP BY club_activity_id;

-- Grant access to the view
GRANT SELECT ON club_activity_interest_counts TO authenticated;
