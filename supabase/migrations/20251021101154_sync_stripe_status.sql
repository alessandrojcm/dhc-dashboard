-- Enable pg_cron extension if not already enabled
create extension if not exists pg_cron;

-- Create a function to sync all customer data from Stripe
create or replace function sync_all_stripe_customers()
returns void
language plpgsql
security definer
as $$
declare
  customer_record record;
begin
  for customer_record in 
    select customer_id 
    from user_profiles 
    where customer_id is not null 
      and customer_id != ''
  loop
    begin
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/stripe-sync',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'service_role_key')
        ),
        body := jsonb_build_object(
          'customer_id', customer_record.customer_id
        )
      );
    exception when others then
      raise warning 'Failed to sync customer %: %', customer_record.customer_id, SQLERRM;
      continue;
    end;
  end loop;
end;
$$;

-- Schedule the sync to run daily at midnight UTC
select cron.schedule(
  'sync-stripe-customers-daily',
  '0 0 * * *',
  $$select sync_all_stripe_customers()$$
);
