-- Create enums
CREATE TYPE club_activity_status AS ENUM ('planned', 'published', 'finished', 'cancelled');

-- Create club_activities table
CREATE TABLE club_activities
(
    id               UUID PRIMARY KEY     DEFAULT gen_random_uuid(),
    title            TEXT        NOT NULL,
    description      TEXT,
    location         TEXT        NOT NULL,
    start_date       TIMESTAMPTZ NOT NULL,
    end_date         TIMESTAMPTZ NOT NULL,
    max_capacity     INTEGER     NOT NULL CHECK (max_capacity > 0),
    price_member     FLOAT       NOT NULL CHECK (price_member >= 0),          -- cents
    price_non_member FLOAT       NOT NULL CHECK (price_non_member >= 0),      -- cents
    is_public        BOOLEAN              DEFAULT false,
    refund_days      INTEGER              DEFAULT 3 CHECK (refund_days >= 0), -- NULL means no refunds
    status           club_activity_status DEFAULT 'planned',
    created_at       TIMESTAMPTZ          DEFAULT now(),
    updated_at       TIMESTAMPTZ          DEFAULT now(),
    created_by       UUID REFERENCES auth.users (id)
);

-- RLS policies
ALTER TABLE club_activities
    ENABLE ROW LEVEL SECURITY;

-- Policy for workshop coordinators - updated to include workshop_coordinator role
CREATE POLICY "Workshop coordinators can manage activities" ON club_activities
    FOR ALL USING (
    (
        (SELECT has_any_role(
                        (SELECT auth.uid()),
                        ARRAY ['workshop_coordinator', 'president', 'admin']::role_type[]
                )))
    );

-- Triggers for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
    RETURNS TRIGGER AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_club_activities_updated_at
    BEFORE UPDATE
    ON club_activities
    FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();