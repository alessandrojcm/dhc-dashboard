-- External users table for non-member registrations
CREATE TABLE external_users
(
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name   TEXT NOT NULL,
    last_name    TEXT NOT NULL,
    email        TEXT NOT NULL UNIQUE,
    phone_number TEXT,
    created_at   TIMESTAMPTZ      DEFAULT NOW(),
    updated_at   TIMESTAMPTZ      DEFAULT NOW()
);

-- RLS Policies for external_users
ALTER TABLE external_users
    ENABLE ROW LEVEL SECURITY;

-- Only committee members can view external user data
CREATE POLICY "Committee can view external users" ON external_users
    FOR SELECT USING (
    has_any_role((select auth.uid()), ARRAY ['admin', 'president', 'beginners_coordinator']::role_type[])
    );

-- Only the registration system (via SECURITY DEFINER functions) can insert external users
-- No direct INSERT policy needed as this will be handled by the register_for_workshop function
CREATE POLICY "System can insert external users" ON external_users
    FOR INSERT WITH CHECK (false);
-- Prevent direct inserts, only via functions

-- Only committee members can update external user data
CREATE POLICY "Committee can update external users" ON external_users
    FOR UPDATE USING (
    has_any_role((select auth.uid()), ARRAY ['admin', 'president', 'beginners_coordinator']::role_type[])
    );

-- Registration status enum
CREATE TYPE registration_status AS ENUM ('pending', 'confirmed', 'cancelled', 'refunded');

-- Club activity registrations table
CREATE TABLE club_activity_registrations
(
    id                         UUID PRIMARY KEY             DEFAULT gen_random_uuid(),
    club_activity_id           UUID                NOT NULL REFERENCES club_activities (id) ON DELETE CASCADE,

    -- User identification (either member or external)
    member_user_id             UUID REFERENCES user_profiles (supabase_user_id) ON DELETE CASCADE,
    external_user_id           UUID REFERENCES external_users (id) ON DELETE CASCADE,

    -- Payment tracking
    stripe_checkout_session_id TEXT UNIQUE,
    amount_paid                INTEGER             NOT NULL, -- in cents
    currency                   TEXT                NOT NULL DEFAULT 'eur',

    -- Registration details
    status                     registration_status NOT NULL DEFAULT 'pending',
    registered_at              TIMESTAMPTZ                  DEFAULT NOW(),
    confirmed_at               TIMESTAMPTZ,
    cancelled_at               TIMESTAMPTZ,

    -- Metadata
    registration_notes         TEXT,
    created_at                 TIMESTAMPTZ                  DEFAULT NOW(),
    updated_at                 TIMESTAMPTZ                  DEFAULT NOW(),

    -- Constraints
    CONSTRAINT registration_user_check CHECK (
        (member_user_id IS NOT NULL AND external_user_id IS NULL) OR
        (member_user_id IS NULL AND external_user_id IS NOT NULL)
        ),
    CONSTRAINT unique_user_per_activity UNIQUE (club_activity_id, member_user_id),
    CONSTRAINT unique_external_user_per_activity UNIQUE (club_activity_id, external_user_id)
);

-- Indexes for performance
CREATE INDEX idx_registrations_activity ON club_activity_registrations (club_activity_id);
CREATE INDEX idx_registrations_member ON club_activity_registrations (member_user_id);
CREATE INDEX idx_registrations_external ON club_activity_registrations (external_user_id);
CREATE INDEX idx_registrations_checkout_session ON club_activity_registrations (stripe_checkout_session_id);
CREATE INDEX idx_registrations_status ON club_activity_registrations (status);

-- RLS Policies for club_activity_registrations
ALTER TABLE club_activity_registrations
    ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Members can view own registrations" ON club_activity_registrations
    FOR SELECT USING (member_user_id = (select auth.uid()));

CREATE POLICY "Committee can view all registrations" ON club_activity_registrations
    FOR SELECT USING (
    has_any_role((select auth.uid()), ARRAY ['admin', 'president', 'beginners_coordinator']::role_type[])
    );

CREATE POLICY "Users can insert own registrations" ON club_activity_registrations
    FOR INSERT WITH CHECK (
    member_user_id = (select auth.uid()) OR
    (member_user_id IS NULL AND external_user_id IS NOT NULL)
    );

CREATE POLICY "Users can update own registrations" ON club_activity_registrations
    FOR UPDATE USING (
    member_user_id = (select auth.uid()) OR
    has_any_role((select auth.uid()), ARRAY ['admin', 'president', 'beginners_coordinator']::role_type[])
    );

-- Capacity validation function
CREATE OR REPLACE FUNCTION check_workshop_capacity(activity_id UUID)
    RETURNS BOOLEAN AS
$$
DECLARE
    current_registrations INTEGER;
    capacity              INTEGER;
BEGIN
    -- Get current confirmed registrations
    SELECT COUNT(*)
    INTO current_registrations
    FROM club_activity_registrations
    WHERE club_activity_id = activity_id
      AND status IN ('confirmed', 'pending');

    -- Get workshop capacity
    SELECT max_capacity
    INTO capacity
    FROM club_activities
    WHERE id = activity_id;

    RETURN current_registrations < capacity;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Registration management function for checkout sessions
CREATE OR REPLACE FUNCTION register_for_workshop_checkout(
    p_activity_id UUID,
    p_amount_paid INTEGER,
    p_stripe_checkout_session_id TEXT,
    p_member_user_id UUID DEFAULT NULL,
    p_external_user_data JSONB DEFAULT NULL
)
    RETURNS UUID AS
$$
DECLARE
    registration_id  UUID;
    external_user_id UUID;
BEGIN
    -- Check capacity
    IF NOT check_workshop_capacity(p_activity_id) THEN
        RAISE EXCEPTION 'Workshop is at full capacity';
    END IF;

    -- Handle external user creation if needed
    IF p_external_user_data IS NOT NULL THEN
        INSERT INTO external_users (first_name, last_name, email, phone_number)
        VALUES (p_external_user_data ->> 'first_name',
                p_external_user_data ->> 'last_name',
                p_external_user_data ->> 'email',
                p_external_user_data ->> 'phone_number')
        ON CONFLICT (email) DO UPDATE SET first_name   = EXCLUDED.first_name,
                                          last_name    = EXCLUDED.last_name,
                                          phone_number = EXCLUDED.phone_number,
                                          updated_at   = NOW()
        RETURNING id INTO external_user_id;
    END IF;

    -- Create registration
    INSERT INTO club_activity_registrations (club_activity_id,
                                             member_user_id,
                                             external_user_id,
                                             amount_paid,
                                             stripe_checkout_session_id,
                                             status)
    VALUES (p_activity_id,
            p_member_user_id,
            external_user_id,
            p_amount_paid,
            p_stripe_checkout_session_id,
            'pending')
    RETURNING id INTO registration_id;

    RETURN registration_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
