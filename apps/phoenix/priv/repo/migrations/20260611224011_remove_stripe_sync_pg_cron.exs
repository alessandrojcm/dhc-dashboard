defmodule Dhc.Repo.Migrations.RemoveStripeSyncPgCron do
  use Ecto.Migration

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'cron') THEN
        PERFORM cron.unschedule('sync-stripe-customers-daily');
      END IF;
    EXCEPTION
      WHEN undefined_function OR invalid_schema_name THEN
        NULL;
    END
    $$;
    """
  end

  def down do
    # The replacement schedule is Oban-managed in Phoenix config; do not
    # recreate the old pg_cron -> Supabase Edge Function trigger.
    :ok
  end
end
