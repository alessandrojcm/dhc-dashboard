-- Enable pg_cron extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Create a function to mark expired invitations
CREATE OR REPLACE FUNCTION public.mark_expired_invitations()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  -- Update invitations that have expired
  UPDATE public.invitations
  SET status = 'expired',
      updated_at = now()
  WHERE status = 'pending'
    AND expires_at < now();
  
  -- Get the count of updated invitations
  GET DIAGNOSTICS v_count = ROW_COUNT;
  
  -- Log the update to a table or return the count
  RETURN v_count;
END;
$$;

-- Schedule the cron job to run daily at 1:00 AM
SELECT cron.schedule(
  'mark-expired-invitations',  -- unique job name
  '0 1 * * *',                -- cron schedule (daily at 1:00 AM)
  $$SELECT public.mark_expired_invitations()$$  -- SQL command to execute
);

-- Grant execute permission on the function
GRANT EXECUTE ON FUNCTION public.mark_expired_invitations() TO postgres;
