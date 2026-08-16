defmodule Dhc.Repo.Migrations.EnforceRequiredFieldsAndDropWaitlistStatusHistory do
  use Ecto.Migration

  @disable_ddl_transaction true

  @moduledoc """
  ALE-186 aligns Principal-owned column names, enforces required values and
  ordering invariants, and removes the empty waitlist status-history orphan.

  Operator pre-flight data gate (every count must be zero):

      SELECT 'notifications_without_principal', count(*) FROM notifications n
        LEFT JOIN principals p ON p.id = n.user_id WHERE p.id IS NULL
      UNION ALL SELECT 'user_profiles.is_active', count(*) FROM user_profiles WHERE is_active IS NULL
      UNION ALL SELECT 'user_profiles.social_media_consent', count(*) FROM user_profiles WHERE social_media_consent IS NULL
      UNION ALL SELECT 'waitlist.initial_registration_date', count(*) FROM waitlist WHERE initial_registration_date IS NULL
      UNION ALL SELECT 'waitlist.last_status_change', count(*) FROM waitlist WHERE last_status_change IS NULL
      UNION ALL SELECT 'club_activities.is_public', count(*) FROM club_activities WHERE is_public IS NULL
      UNION ALL SELECT 'club_activities.status', count(*) FROM club_activities WHERE status IS NULL
      UNION ALL SELECT 'club_activities.announce_discord', count(*) FROM club_activities WHERE announce_discord IS NULL
      UNION ALL SELECT 'club_activities.announce_email', count(*) FROM club_activities WHERE announce_email IS NULL
      UNION ALL SELECT 'member_profiles.membership_dates', count(*) FROM member_profiles WHERE membership_end_date < membership_start_date
      UNION ALL SELECT 'notifications.read_at', count(*) FROM notifications WHERE read_at < created_at
      UNION ALL SELECT 'invitation_processing_logs.counts', count(*) FROM invitation_processing_logs WHERE total_count < 0 OR success_count < 0 OR failure_count < 0
      UNION ALL SELECT 'waitlist_status_history', count(*) FROM waitlist_status_history;

  The migration repeats these gates and aborts before changing the schema if
  production data violates any assumption.
  """

  @member_dates_check :member_profiles_membership_dates_order_check
  @notification_dates_check :notifications_read_after_created_check
  @processing_counts_check :invitation_processing_logs_non_negative_counts_check

  def up do
    run_data_gates!()

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'user_id'
      ) THEN
        ALTER TABLE notifications RENAME COLUMN user_id TO principal_id;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'notifications_principal_id_fkey'
          AND conrelid = 'notifications'::regclass
      ) THEN
        ALTER TABLE notifications
          ADD CONSTRAINT notifications_principal_id_fkey
          FOREIGN KEY (principal_id) REFERENCES principals(id) ON DELETE CASCADE;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_audit_log' AND column_name = 'user_id'
      ) THEN
        ALTER TABLE user_audit_log RENAME COLUMN user_id TO principal_id;
      END IF;

      ALTER TABLE notifications ALTER COLUMN principal_id SET NOT NULL;
      ALTER TABLE user_profiles ALTER COLUMN is_active SET NOT NULL;
      ALTER TABLE user_profiles ALTER COLUMN social_media_consent SET NOT NULL;
      ALTER TABLE waitlist ALTER COLUMN initial_registration_date SET NOT NULL;
      ALTER TABLE waitlist ALTER COLUMN last_status_change SET NOT NULL;
      ALTER TABLE club_activities ALTER COLUMN is_public SET NOT NULL;
      ALTER TABLE club_activities ALTER COLUMN status SET NOT NULL;
      ALTER TABLE club_activities ALTER COLUMN announce_discord SET NOT NULL;
      ALTER TABLE club_activities ALTER COLUMN announce_email SET NOT NULL;

      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{@member_dates_check}' AND conrelid = 'member_profiles'::regclass
      ) THEN
        ALTER TABLE member_profiles
          ADD CONSTRAINT #{@member_dates_check}
          CHECK (membership_end_date IS NULL OR membership_end_date >= membership_start_date)
          NOT VALID;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{@notification_dates_check}' AND conrelid = 'notifications'::regclass
      ) THEN
        ALTER TABLE notifications
          ADD CONSTRAINT #{@notification_dates_check}
          CHECK (read_at IS NULL OR read_at >= created_at)
          NOT VALID;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = '#{@processing_counts_check}'
          AND conrelid = 'invitation_processing_logs'::regclass
      ) THEN
        ALTER TABLE invitation_processing_logs
          ADD CONSTRAINT #{@processing_counts_check}
          CHECK (total_count >= 0 AND success_count >= 0 AND failure_count >= 0)
          NOT VALID;
      END IF;
    END
    $$
    """

    execute "ALTER TABLE member_profiles VALIDATE CONSTRAINT #{@member_dates_check}"
    execute "ALTER TABLE notifications VALIDATE CONSTRAINT #{@notification_dates_check}"

    execute "ALTER TABLE invitation_processing_logs VALIDATE CONSTRAINT #{@processing_counts_check}"

    execute "DROP TABLE IF EXISTS waitlist_status_history"
  end

  def down do
    execute """
    CREATE TABLE IF NOT EXISTS waitlist_status_history (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      waitlist_id uuid REFERENCES waitlist(id),
      old_status waitlist_status,
      new_status waitlist_status NOT NULL,
      changed_at timestamptz DEFAULT NOW(),
      changed_by uuid REFERENCES principals(id),
      notes text
    )
    """

    execute """
    DO $$
    BEGIN
      ALTER TABLE invitation_processing_logs
        DROP CONSTRAINT IF EXISTS #{@processing_counts_check};
      ALTER TABLE notifications DROP CONSTRAINT IF EXISTS #{@notification_dates_check};
      ALTER TABLE member_profiles DROP CONSTRAINT IF EXISTS #{@member_dates_check};

      ALTER TABLE club_activities ALTER COLUMN is_public DROP NOT NULL;
      ALTER TABLE club_activities ALTER COLUMN status DROP NOT NULL;
      ALTER TABLE club_activities ALTER COLUMN announce_discord DROP NOT NULL;
      ALTER TABLE club_activities ALTER COLUMN announce_email DROP NOT NULL;
      ALTER TABLE waitlist ALTER COLUMN initial_registration_date DROP NOT NULL;
      ALTER TABLE waitlist ALTER COLUMN last_status_change DROP NOT NULL;
      ALTER TABLE user_profiles ALTER COLUMN is_active DROP NOT NULL;
      ALTER TABLE user_profiles ALTER COLUMN social_media_consent DROP NOT NULL;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'user_audit_log' AND column_name = 'principal_id'
      ) THEN
        ALTER TABLE user_audit_log RENAME COLUMN principal_id TO user_id;
      END IF;

      ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_principal_id_fkey;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'principal_id'
      ) THEN
        ALTER TABLE notifications RENAME COLUMN principal_id TO user_id;
      END IF;
    END
    $$
    """
  end

  defp run_data_gates! do
    execute """
    DO $$
    DECLARE
      failures text;
      notification_owner_column text;
      notification_orphans bigint;
      history_rows bigint := 0;
    BEGIN
      SELECT CASE
        WHEN EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'notifications' AND column_name = 'user_id'
        ) THEN 'user_id'
        ELSE 'principal_id'
      END INTO notification_owner_column;

      EXECUTE format(
        'SELECT count(*) FROM notifications n LEFT JOIN principals p ON p.id = n.%I WHERE p.id IS NULL',
        notification_owner_column
      ) INTO notification_orphans;

      IF to_regclass('public.waitlist_status_history') IS NOT NULL THEN
        SELECT count(*) INTO history_rows FROM waitlist_status_history;
      END IF;

      SELECT string_agg(gate || '=' || count, ', ' ORDER BY gate)
      INTO failures
      FROM (
        SELECT 'notifications_without_principal' AS gate, notification_orphans::text AS count
        UNION ALL SELECT 'user_profiles.is_active', count(*)::text FROM user_profiles WHERE is_active IS NULL
        UNION ALL SELECT 'user_profiles.social_media_consent', count(*)::text FROM user_profiles WHERE social_media_consent IS NULL
        UNION ALL SELECT 'waitlist.initial_registration_date', count(*)::text FROM waitlist WHERE initial_registration_date IS NULL
        UNION ALL SELECT 'waitlist.last_status_change', count(*)::text FROM waitlist WHERE last_status_change IS NULL
        UNION ALL SELECT 'club_activities.is_public', count(*)::text FROM club_activities WHERE is_public IS NULL
        UNION ALL SELECT 'club_activities.status', count(*)::text FROM club_activities WHERE status IS NULL
        UNION ALL SELECT 'club_activities.announce_discord', count(*)::text FROM club_activities WHERE announce_discord IS NULL
        UNION ALL SELECT 'club_activities.announce_email', count(*)::text FROM club_activities WHERE announce_email IS NULL
        UNION ALL SELECT 'member_profiles.membership_dates', count(*)::text FROM member_profiles WHERE membership_end_date < membership_start_date
        UNION ALL SELECT 'notifications.read_at', count(*)::text FROM notifications WHERE read_at < created_at
        UNION ALL SELECT 'invitation_processing_logs.counts', count(*)::text FROM invitation_processing_logs WHERE total_count < 0 OR success_count < 0 OR failure_count < 0
        UNION ALL SELECT 'waitlist_status_history', history_rows::text
      ) gates
      WHERE count <> '0';

      IF failures IS NOT NULL THEN
        RAISE EXCEPTION 'Required-field data gate failed: %', failures;
      END IF;
    END
    $$
    """
  end
end
