-- Create a function to call the workshop topup edge function
CREATE OR REPLACE FUNCTION public.trigger_workshop_topup()
    RETURNS TEXT
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS
$$
DECLARE
    v_response TEXT;
BEGIN
    -- Call the workshop_topup edge function via HTTP
    select net.http_post(
                   url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') ||
                          '/functions/v1/workshop_topup',
                   headers := jsonb_build_object(
                           'Content-type', 'application/json',
                           'Authorization', 'Bearer ' || (select decrypted_secret
                                                          from vault.decrypted_secrets
                                                          where name = 'service_role_key')
                              ),
                   body := concat('{"time": "', now(), '"}')::jsonb
           )
    into v_response;

    RETURN 'Workshop topup scheduled: ' || COALESCE(v_response, 'No response');
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'Error triggering workshop topup: ' || SQLERRM;
END;
$$;

-- Schedule the cron job to run daily at 9:00 AM
SELECT cron.schedule(
               'workshop-topup-daily', -- unique job name
               '0 9 * * *', -- cron schedule (daily at 9:00 AM)
               $$SELECT public.trigger_workshop_topup()$$ -- SQL command to execute
       );

-- Grant execute permission on the function
GRANT EXECUTE ON FUNCTION public.trigger_workshop_topup() TO postgres;
