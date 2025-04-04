-- Enable pg_cron extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Create a function to clean up expired payment sessions
CREATE OR REPLACE FUNCTION public.cleanup_payment_sessions()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  -- Delete expired and unused payment sessions
  DELETE FROM public.payment_sessions
  WHERE (expires_at < now() AND is_used = false) OR
        (created_at < now() - INTERVAL '30 days');
  
  -- Get the count of deleted payment sessions
  GET DIAGNOSTICS v_count = ROW_COUNT;
  
  -- Return the count of deleted sessions
  RETURN v_count;
END;
$$;

-- Schedule the cron job to run daily at 2:00 AM
SELECT cron.schedule(
  'cleanup-payment-sessions',  -- unique job name
  '0 2 * * *',                -- cron schedule (daily at 2:00 AM)
  $$SELECT public.cleanup_payment_sessions()$$  -- SQL command to execute
);

-- Grant execute permission on the function
GRANT EXECUTE ON FUNCTION public.cleanup_payment_sessions() TO postgres;
