create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function public.sync_all_stripe_customers()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/stripe-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := '{}'::jsonb
  );
exception
  when others then
    raise warning 'Failed to trigger stripe-sync batch: %', SQLERRM;
end;
$$;

do $$
declare
  stripe_sync_job record;
begin
  for stripe_sync_job in
    select jobid
    from cron.job
    where jobname = 'sync-stripe-customers-daily'
  loop
    perform cron.unschedule(stripe_sync_job.jobid);
  end loop;
end;
$$;

select cron.schedule(
  'sync-stripe-customers-daily',
  '0 0 * * *',
  $$select public.sync_all_stripe_customers()$$
);
