-- Refund status enum
CREATE TYPE refund_status AS ENUM ('pending', 'processing', 'completed', 'failed', 'cancelled');

-- Refunds table
CREATE TABLE club_activity_refunds (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id       UUID NOT NULL REFERENCES club_activity_registrations(id) ON DELETE CASCADE,
    
    -- Refund details
    refund_amount         INTEGER NOT NULL, -- in cents
    refund_reason         TEXT,
    status                refund_status NOT NULL DEFAULT 'pending',
    
    -- Stripe integration
    stripe_refund_id      TEXT UNIQUE,
    stripe_payment_intent_id TEXT,
    
    -- Timestamps
    requested_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at          TIMESTAMPTZ,
    completed_at          TIMESTAMPTZ,
    
    -- Audit fields
    requested_by          UUID REFERENCES auth.users(id),
    processed_by          UUID REFERENCES auth.users(id),
    
    created_at            TIMESTAMPTZ DEFAULT NOW(),
    updated_at            TIMESTAMPTZ DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT refund_amount_positive CHECK (refund_amount > 0),
    CONSTRAINT one_refund_per_registration UNIQUE (registration_id)
);

-- Indexes
CREATE INDEX idx_refunds_registration ON club_activity_refunds (registration_id);
CREATE INDEX idx_refunds_status ON club_activity_refunds (status);
CREATE INDEX idx_refunds_stripe_refund ON club_activity_refunds (stripe_refund_id);
CREATE INDEX idx_refunds_requested_at ON club_activity_refunds (requested_at);

-- RLS Policies
ALTER TABLE club_activity_refunds ENABLE ROW LEVEL SECURITY;

-- Members can view their own refunds
CREATE POLICY "Members can view own refunds" ON club_activity_refunds
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM club_activity_registrations car
            WHERE car.id = registration_id 
            AND car.member_user_id = (SELECT auth.uid())
        )
    );

-- Committee can view all refunds
CREATE POLICY "Committee can view all refunds" ON club_activity_refunds
    FOR SELECT USING (
        has_any_role((SELECT auth.uid()), ARRAY['admin', 'president', 'workshop_coordinator']::role_type[])
    );

-- Committee can manage refunds
CREATE POLICY "Committee can manage refunds" ON club_activity_refunds
    FOR ALL USING (
        has_any_role((SELECT auth.uid()), ARRAY['admin', 'president', 'workshop_coordinator']::role_type[])
    );

-- Add attendance tracking to existing registrations table
ALTER TABLE club_activity_registrations 
ADD COLUMN attendance_status TEXT CHECK (attendance_status IN ('pending', 'attended', 'no_show', 'excused')) DEFAULT 'pending',
ADD COLUMN attendance_marked_at TIMESTAMPTZ,
ADD COLUMN attendance_marked_by UUID REFERENCES auth.users(id),
ADD COLUMN attendance_notes TEXT;

-- Index for attendance queries
CREATE INDEX idx_registrations_attendance_status ON club_activity_registrations (attendance_status);
CREATE INDEX idx_registrations_attendance_marked_at ON club_activity_registrations (attendance_marked_at);

-- Update trigger for refunds
CREATE TRIGGER update_club_activity_refunds_updated_at
    BEFORE UPDATE ON club_activity_refunds
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function to check refund eligibility
CREATE OR REPLACE FUNCTION check_refund_eligibility(registration_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    reg_status registration_status;
    workshop_status club_activity_status;
    workshop_start_date TIMESTAMPTZ;
    workshop_refund_days INTEGER;
    refund_deadline TIMESTAMPTZ;
BEGIN
    -- Get registration and workshop details
    SELECT car.status, ca.status, ca.start_date, ca.refund_days
    INTO reg_status, workshop_status, workshop_start_date, workshop_refund_days
    FROM club_activity_registrations car
    JOIN club_activities ca ON car.club_activity_id = ca.id
    WHERE car.id = registration_id;
    
    -- Check if registration exists
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    
    -- Check if already refunded
    IF EXISTS (SELECT 1 FROM club_activity_refunds WHERE registration_id = registration_id) THEN
        RETURN FALSE;
    END IF;
    
    -- Check if registration is confirmed/paid
    IF reg_status NOT IN ('confirmed', 'pending') THEN
        RETURN FALSE;
    END IF;
    
    -- Check workshop status
    IF workshop_status IN ('finished', 'cancelled') THEN
        RETURN FALSE;
    END IF;
    
    -- Check refund deadline if set
    IF workshop_refund_days IS NOT NULL THEN
        refund_deadline := workshop_start_date - (workshop_refund_days || ' days')::INTERVAL;
        IF NOW() > refund_deadline THEN
            RETURN FALSE;
        END IF;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to calculate refund amount
CREATE OR REPLACE FUNCTION calculate_refund_amount(registration_id UUID)
RETURNS INTEGER AS $$
DECLARE
    amount_paid INTEGER;
BEGIN
    SELECT car.amount_paid INTO amount_paid
    FROM club_activity_registrations car
    WHERE car.id = registration_id;
    
    -- For now, full refund if eligible
    -- Future: could implement partial refunds based on timing
    RETURN COALESCE(amount_paid, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;