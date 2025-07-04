-- Fix the prioritized waitlist function to include phone number and user_profile_id
-- This eliminates the need for multiple queries in the application code

-- Drop the existing function first since we're changing the return type
DROP FUNCTION IF EXISTS get_prioritized_waitlist_for_workshop(uuid, integer);

CREATE OR REPLACE FUNCTION get_prioritized_waitlist_for_workshop(
    workshop_id_param uuid,
    limit_param integer DEFAULT NULL
)
RETURNS TABLE (
    waitlist_id uuid,
    email text,
    user_profile_id uuid,
    first_name text,
    last_name text,
    phone_number text,
    priority_level integer,
    created_at timestamptz,
    admin_notes text
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        wl.id as waitlist_id,
        wl.email,
        up.id as user_profile_id,
        up.first_name,
        up.last_name,
        up.phone_number,
        wl.priority_level,
        up.created_at,
        wl.admin_notes
    FROM waitlist wl
    LEFT JOIN public.user_profiles up ON up.waitlist_id = wl.id
    WHERE wl.status = 'waiting'  -- Only people waiting for their first beginner's workshop
    AND up.id IS NOT NULL  -- Ensure we have a valid user profile
    -- Exclude people who cancelled from this specific workshop
    AND (wl.previous_workshop_id IS NULL OR wl.previous_workshop_id != workshop_id_param)
    -- Exclude people already invited to this workshop
    AND NOT EXISTS (
        SELECT 1 FROM workshop_attendees wa
        WHERE wa.user_profile_id = up.id
        AND wa.workshop_id = workshop_id_param
    )
    ORDER BY 
        wl.priority_level DESC,
        up.created_at ASC  -- FIFO within same priority
    LIMIT limit_param;
END;
$$ LANGUAGE plpgsql;