-- Add refunds and cancellations support
-- This migration adds fields to support workshop attendee cancellations and refunds

-- First, ensure 'cancelled' status exists in workshop_attendee_status enum
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_enum WHERE enumlabel = 'cancelled' AND enumtypid = (SELECT oid FROM pg_type WHERE typname = 'workshop_attendee_status')) THEN
        ALTER TYPE workshop_attendee_status ADD VALUE 'cancelled';
    END IF;
END $$;

-- Add cancellation and refund tracking fields to workshop_attendees table
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS cancelled_by uuid REFERENCES user_profiles(id);
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS refund_requested boolean DEFAULT false;
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS stripe_refund_id text;
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS refund_processed_at timestamptz;
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS waitlist_return_requested boolean DEFAULT false;

-- Add priority system fields to waitlist table
ALTER TABLE waitlist ADD COLUMN IF NOT EXISTS priority_level integer DEFAULT 0;
ALTER TABLE waitlist ADD COLUMN IF NOT EXISTS previous_workshop_id uuid REFERENCES workshops(id);
ALTER TABLE waitlist ADD COLUMN IF NOT EXISTS has_paid_credit boolean DEFAULT false;

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_workshop_attendees_cancelled_at ON workshop_attendees(cancelled_at);
CREATE INDEX IF NOT EXISTS idx_workshop_attendees_cancelled_by ON workshop_attendees(cancelled_by);
CREATE INDEX IF NOT EXISTS idx_workshop_attendees_refund_requested ON workshop_attendees(refund_requested);
CREATE INDEX IF NOT EXISTS idx_waitlist_priority_level ON waitlist(priority_level);
CREATE INDEX IF NOT EXISTS idx_waitlist_previous_workshop_id ON waitlist(previous_workshop_id);

-- Add comments for documentation
COMMENT ON COLUMN workshop_attendees.cancelled_at IS 'Timestamp when the attendee was cancelled';
COMMENT ON COLUMN workshop_attendees.cancelled_by IS 'Admin user who cancelled the attendee';
COMMENT ON COLUMN workshop_attendees.refund_requested IS 'Whether a refund was requested for this attendee';
COMMENT ON COLUMN workshop_attendees.stripe_refund_id IS 'Stripe refund ID if refund was processed';
COMMENT ON COLUMN workshop_attendees.refund_processed_at IS 'Timestamp when refund was processed';
COMMENT ON COLUMN workshop_attendees.waitlist_return_requested IS 'Whether attendee requested to return to waitlist';

COMMENT ON COLUMN waitlist.priority_level IS 'Priority level: 0=normal, 1=cancelled_priority, 2=manual_priority';
COMMENT ON COLUMN waitlist.previous_workshop_id IS 'Workshop ID that this person cancelled from (for exclusion logic)';
COMMENT ON COLUMN waitlist.has_paid_credit IS 'Whether this person has a paid credit from a previous cancellation';

-- Create function to handle priority reset after workshop completion
CREATE OR REPLACE FUNCTION reset_waitlist_priority_after_workshop(workshop_id_param uuid)
RETURNS void AS $$
BEGIN
    -- Reset priority level to 0 for attendees who had priority from this workshop
    UPDATE waitlist 
    SET 
        priority_level = 0,
        admin_notes = CASE 
            WHEN admin_notes IS NOT NULL THEN 
                admin_notes || ' [Priority expired after workshop ' || workshop_id_param || ']'
            ELSE 
                '[Priority expired after workshop ' || workshop_id_param || ']'
        END
    WHERE priority_level = 1 
    AND previous_workshop_id = workshop_id_param;
    
    -- Log the operation
    RAISE NOTICE 'Reset priority for waitlist entries from workshop %', workshop_id_param;
END;
$$ LANGUAGE plpgsql;

-- Create function to move cancelled attendee back to waitlist with priority
CREATE OR REPLACE FUNCTION move_cancelled_attendee_to_waitlist(
    attendee_id_param uuid,
    workshop_id_param uuid,
    admin_notes_param text DEFAULT NULL
)
RETURNS uuid AS $$
DECLARE
    user_profile_record RECORD;
    waitlist_entry_id uuid;
BEGIN
    -- Get the user profile info from the attendee
    SELECT up.id, up.waitlist_id, wl.email, up.first_name, up.last_name
    INTO user_profile_record
    FROM workshop_attendees wa
    JOIN user_profiles up ON wa.user_profile_id = up.id
    JOIN waitlist wl ON up.waitlist_id = wl.id
    WHERE wa.id = attendee_id_param;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Attendee not found or no associated waitlist entry';
    END IF;
    
    -- Update the existing waitlist entry with priority
    UPDATE waitlist 
    SET 
        priority_level = 1,
        previous_workshop_id = workshop_id_param,
        admin_notes = CASE 
            WHEN admin_notes_param IS NOT NULL THEN 
                COALESCE(admin_notes, '') || ' [Cancelled from workshop, given priority] ' || admin_notes_param
            ELSE 
                COALESCE(admin_notes, '') || ' [Cancelled from workshop, given priority]'
        END
    WHERE id = user_profile_record.waitlist_id;
    
    RETURN user_profile_record.waitlist_id;
END;
$$ LANGUAGE plpgsql;

-- Create function to get prioritized waitlist for workshop invitations
CREATE OR REPLACE FUNCTION get_prioritized_waitlist_for_workshop(
    workshop_id_param uuid,
    limit_param integer DEFAULT NULL
)
RETURNS TABLE (
    waitlist_id uuid,
    email text,
    first_name text,
    last_name text,
    priority_level integer,
    created_at timestamptz,
    admin_notes text
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        wl.id as waitlist_id,
        wl.email,
        up.first_name,
        up.last_name,
        wl.priority_level,
        up.created_at,
        wl.admin_notes
    FROM waitlist wl
    LEFT JOIN public.user_profiles up ON up.waitlist_id = wl.id
    WHERE wl.status = 'active'
    -- Exclude people who cancelled from this specific workshop
    AND (wl.previous_workshop_id IS NULL OR wl.previous_workshop_id != workshop_id_param)
    -- Exclude people already invited to this workshop
    AND NOT EXISTS (
        SELECT 1 FROM workshop_attendees wa
        JOIN user_profiles up ON wa.user_profile_id = up.id
        WHERE up.waitlist_id = wl.id
        AND wa.workshop_id = workshop_id_param
    )
    ORDER BY 
        wl.priority_level DESC
    LIMIT limit_param;
END;
$$ LANGUAGE plpgsql;

-- Update RLS policies to include new fields
-- Allow admins to see cancellation and refund data
CREATE POLICY "Admins can see cancellation data" ON workshop_attendees FOR SELECT
    USING (has_any_role((select auth.uid()), array['admin', 'president', 'coach']::role_type[]));

-- Allow admins to update cancellation and refund fields
CREATE POLICY "Admins can update cancellation data" ON workshop_attendees FOR UPDATE
    USING (has_any_role((select auth.uid()), array['admin', 'president', 'coach']::role_type[]))
    WITH CHECK (has_any_role((select auth.uid()), array['admin', 'president', 'coach']::role_type[]));
