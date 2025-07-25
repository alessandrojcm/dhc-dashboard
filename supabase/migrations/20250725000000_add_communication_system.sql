-- Add announcement fields to club_activities table
ALTER TABLE club_activities 
ADD COLUMN announce_discord BOOLEAN DEFAULT false,
ADD COLUMN announce_email BOOLEAN DEFAULT false;

-- Create workshop_announcement queue using pgmq
SELECT pgmq.create('workshop_announcement');

-- Create discord_queue using pgmq (similar to existing email_queue)
SELECT pgmq.create('discord_queue');

-- Create function to add workshop to announcement queue
CREATE OR REPLACE FUNCTION queue_workshop_announcement(
    workshop_id UUID,
    announcement_type TEXT DEFAULT 'created'
)
RETURNS VOID AS $$
BEGIN
    -- Add workshop to announcement queue with metadata
    PERFORM pgmq.send(
        'workshop_announcement',
        jsonb_build_object(
            'workshop_id', workshop_id,
            'announcement_type', announcement_type,
            'queued_at', NOW()
        )
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger function to queue announcements on workshop changes
CREATE OR REPLACE FUNCTION trigger_workshop_announcement()
RETURNS TRIGGER AS $$
DECLARE
    announcement_type TEXT;
    should_announce BOOLEAN := false;
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
        PERFORM queue_workshop_announcement(NEW.id, announcement_type);
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger for workshop announcements
CREATE TRIGGER workshop_announcement_trigger
    AFTER INSERT OR UPDATE ON club_activities
    FOR EACH ROW
    EXECUTE FUNCTION trigger_workshop_announcement();

-- Create function to get active users for announcements
CREATE OR REPLACE FUNCTION get_active_users_for_announcements()
RETURNS TABLE(
    user_id UUID,
    email TEXT,
    first_name TEXT,
    last_name TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        up.supabase_user_id,
        au.email,
        up.first_name,
        up.last_name
    FROM user_profiles up
    LEFT JOIN auth.users au ON up.supabase_user_id = au.id
    WHERE up.is_active = true
    AND au.email IS NOT NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant necessary permissions
GRANT EXECUTE ON FUNCTION queue_workshop_announcement(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_active_users_for_announcements() TO authenticated;

-- Create cron job to process workshop announcements daily at noon
SELECT cron.schedule(
    'process-workshop-announcements',
    '0 12 * * *', -- Daily at 12:00 PM
    $$
    SELECT
        net.http_post(
            url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/process-workshop-announcements',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key')
            ),
            body := jsonb_build_object()
        ) as request_id;
    $$
);

-- Create cron job to process Discord queue (runs every 5 minutes)
SELECT cron.schedule(
    'process-discord-queue',
    '0 12 * * *', -- Daily at 12:00 PM
    $$
    SELECT
        net.http_post(
            url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/process-discord',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key')
            ),
            body := jsonb_build_object()
        ) as request_id;
    $$
);
