create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists pgmq;

select
from pgmq.create('email_queue');
select vault.create_secret('http://supabase_kong_dhc-dashboard:8000', 'project_url');
select vault.create_secret('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0', 'service_role_key');

-- Create a cron job that runs every 5 minutes to call the process-emails edge function
select cron.schedule(
'process-emails-every-5-minutes',
'*/5 * * * *', -- every minute
$$
    select
      net.http_post(
          url:= (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/process-emails',
          headers:=jsonb_build_object(
            'Content-type', 'application/json',
            'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
          ),
          body:=concat('{"time": "', now(), '"}')::jsonb
      ) as request_id;
$$
);
