alter function public.mark_notification_as_read set search_path = '';
alter function public.check_workshop_capacity set search_path = '';
alter function public.check_refund_eligibility set search_path = '';
alter function public.calculate_refund_amount set search_path = '';
alter function public.trigger_workshop_announcement set search_path = '';
alter function public.queue_workshop_announcement set search_path = '';
alter function public.get_active_users_for_announcements set search_path = '';
alter function public.custom_access_token_hook set search_path = '';
alter function public.update_settings_updated_at set search_path = '';
alter function public.trigger_set_updated_at set search_path = '';
alter function public.get_current_user_with_profile set search_path  = '';
alter function public.get_membership_info set search_path  = '';
alter function public.get_weapons_options set search_path  = '';
alter function public.update_updated_at_column set search_path = '';


-- Create interest count view for performance
CREATE OR REPLACE VIEW club_activity_interest_counts with(security_invoker=true) AS
SELECT club_activity_id,
       COUNT(*) as interest_count
FROM club_activity_interest
GROUP BY club_activity_id;

-- Grant access to the view
GRANT SELECT ON club_activity_interest_counts TO authenticated;


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
    IF NOT public.check_workshop_capacity(p_activity_id) THEN
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
$$ LANGUAGE plpgsql SECURITY DEFINER
                    set search_path = '';

-- Fix search_path for util schema functions (if they exist)
-- These may be created by extensions or other processes
DO
$$
    BEGIN
        -- Try to fix util.project_url if it exists
        IF EXISTS (SELECT 1
                   FROM pg_proc p
                            JOIN pg_namespace n ON p.pronamespace = n.oid
                   WHERE n.nspname = 'util'
                     AND p.proname = 'project_url') THEN
            EXECUTE 'alter function util.project_url set search_path = ''''';
        END IF;

        -- Try to fix util.invoke_edge_function if it exists
        IF EXISTS (SELECT 1
                   FROM pg_proc p
                            JOIN pg_namespace n ON p.pronamespace = n.oid
                   WHERE n.nspname = 'util'
                     AND p.proname = 'invoke_edge_function') THEN
            EXECUTE 'alter function util.invoke_edge_function set search_path = ''''';
        END IF;

        -- Try to fix util.clear_column if it exists
        IF EXISTS (SELECT 1
                   FROM pg_proc p
                            JOIN pg_namespace n ON p.pronamespace = n.oid
                   WHERE n.nspname = 'util'
                     AND p.proname = 'clear_column') THEN
            EXECUTE 'alter function util.clear_column set search_path = ''''';
        END IF;

        -- Try to fix util.process_embeddings if it exists
        IF EXISTS (SELECT 1
                   FROM pg_proc p
                            JOIN pg_namespace n ON p.pronamespace = n.oid
                   WHERE n.nspname = 'util'
                     AND p.proname = 'process_embeddings') THEN
            EXECUTE 'alter function util.process_embeddings set search_path = ''''';
        END IF;
    END
$$;

-- Fix function calls that need schema prefixes due to search_path = ''

-- Fix trigger_workshop_announcement function to use schema prefix
CREATE OR REPLACE FUNCTION public.trigger_workshop_announcement()
    RETURNS TRIGGER AS
$$
DECLARE
    announcement_type TEXT;
    should_announce   BOOLEAN := false;
BEGIN
    -- Determine announcement type and if we should announce
    IF TG_OP = 'INSERT' THEN
        announcement_type := 'created';
        should_announce := NEW.announce_discord OR NEW.announce_email;
    ELSIF TG_OP = 'UPDATE' THEN
        -- Only announce for specific changes
        IF OLD.status != NEW.status THEN
            announcement_type := 'status_changed';
            should_announce := NEW.announce_discord OR NEW.announce_email;
        ELSIF OLD.start_date != NEW.start_date OR OLD.end_date != NEW.end_date THEN
            announcement_type := 'time_changed';
            should_announce := NEW.announce_discord OR NEW.announce_email;
        ELSIF OLD.location != NEW.location THEN
            announcement_type := 'location_changed';
            should_announce := NEW.announce_discord OR NEW.announce_email;
        END IF;
    END IF;

    -- Queue announcement if needed
    IF should_announce THEN
        PERFORM public.queue_workshop_announcement(NEW.id, announcement_type);
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
                    set search_path = '';

-- Fix check_workshop_capacity function to use schema prefixes
CREATE OR REPLACE FUNCTION public.check_workshop_capacity(activity_id UUID)
    RETURNS BOOLEAN AS
$$
DECLARE
    current_registrations INTEGER;
    capacity              INTEGER;
BEGIN
    -- Get current confirmed registrations
    SELECT COUNT(*)
    INTO current_registrations
    FROM public.club_activity_registrations
    WHERE club_activity_id = activity_id
      AND status IN ('confirmed', 'pending');

    -- Get workshop capacity
    SELECT max_capacity
    INTO capacity
    FROM public.club_activities
    WHERE id = activity_id;

    RETURN current_registrations < capacity;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
                    set search_path = '';

-- Drop and recreate check_refund_eligibility function to avoid parameter name conflicts
DROP FUNCTION IF EXISTS public.check_refund_eligibility(UUID);

-- Fix check_refund_eligibility function to use schema prefixes
CREATE FUNCTION public.check_refund_eligibility(reg_id UUID)
    RETURNS BOOLEAN AS
$$
DECLARE
    reg_status           public.registration_status;
    workshop_status      public.club_activity_status;
    workshop_start_date  TIMESTAMPTZ;
    workshop_refund_days INTEGER;
    refund_deadline      TIMESTAMPTZ;
BEGIN
    -- Get registration and workshop details
    SELECT car.status, ca.status, ca.start_date, ca.refund_days
    INTO reg_status, workshop_status, workshop_start_date, workshop_refund_days
    FROM public.club_activity_registrations car
             JOIN public.club_activities ca ON car.club_activity_id = ca.id
    WHERE car.id = reg_id;

    -- Check if registration exists
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Check if already refunded
    IF EXISTS (SELECT 1
               FROM public.club_activity_refunds
               WHERE public.club_activity_refunds.registration_id = reg_id) THEN
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
$$ LANGUAGE plpgsql SECURITY DEFINER
                    set search_path = '';

-- Fix calculate_refund_amount function to use schema prefixes
CREATE OR REPLACE FUNCTION public.calculate_refund_amount(registration_id UUID)
    RETURNS INTEGER AS
$$
DECLARE
    amount_paid INTEGER;
BEGIN
    SELECT car.amount_paid
    INTO amount_paid
    FROM public.club_activity_registrations car
    WHERE car.id = registration_id;

    -- For now, full refund if eligible
    -- Future: could implement partial refunds based on timing
    RETURN COALESCE(amount_paid, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
                    set search_path = '';

-- Fix get_active_users_for_announcements function to use schema prefixes
CREATE OR REPLACE FUNCTION public.get_active_users_for_announcements()
    RETURNS TABLE
            (
                user_id    UUID,
                email      TEXT,
                first_name TEXT,
                last_name  TEXT
            )
AS
$$
BEGIN
    RETURN QUERY
        SELECT up.supabase_user_id,
               au.email,
               up.first_name,
               up.last_name
        FROM public.user_profiles up
                 LEFT JOIN auth.users au ON up.supabase_user_id = au.id
        WHERE up.is_active = true
          AND au.email IS NOT NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
                    set search_path = '';

-- Fix register_for_workshop_checkout function to use schema prefixes for table references
CREATE OR REPLACE FUNCTION public.register_for_workshop_checkout(
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
    IF NOT public.check_workshop_capacity(p_activity_id) THEN
        RAISE EXCEPTION 'Workshop is at full capacity';
    END IF;

    -- Handle external user creation if needed
    IF p_external_user_data IS NOT NULL THEN
        INSERT INTO public.external_users (first_name, last_name, email, phone_number)
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
    INSERT INTO public.club_activity_registrations (club_activity_id,
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
$$ LANGUAGE plpgsql SECURITY DEFINER
                    set search_path = '';
