defmodule Dhc.Repo.Migrations.Ale185HighValueIndexesAndRedundantIndexDrops do
  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS club_activities_status_start_date_index
      ON club_activities (status, start_date)
    """

    execute """
    CREATE INDEX IF NOT EXISTS notifications_principal_id_created_at_id_index
      ON notifications (principal_id, created_at DESC, id DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS notifications_unread_principal_id_index
      ON notifications (principal_id) WHERE read_at IS NULL
    """

    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'club_activities_end_after_start_check'
          AND conrelid = 'club_activities'::regclass
      ) THEN
        ALTER TABLE club_activities
          ADD CONSTRAINT club_activities_end_after_start_check
          CHECK (end_date > start_date);
      END IF;
    END
    $$
    """

    execute "DROP INDEX IF EXISTS user_profiles_first_name_last_name_index"
    execute "DROP INDEX IF EXISTS club_activity_registrations_status_index"
    execute "DROP INDEX IF EXISTS club_activity_registrations_attendance_status_index"
    execute "DROP INDEX IF EXISTS club_activity_registrations_attendance_marked_at_index"
    execute "DROP INDEX IF EXISTS club_activity_refunds_status_index"
    execute "DROP INDEX IF EXISTS notifications_user_id_index"
    execute "DROP INDEX IF EXISTS notifications_created_at_index"
  end

  def down do
    execute "DROP INDEX IF EXISTS notifications_unread_principal_id_index"
    execute "DROP INDEX IF EXISTS notifications_principal_id_created_at_id_index"
    execute "DROP INDEX IF EXISTS club_activities_status_start_date_index"

    execute """
    ALTER TABLE club_activities
      DROP CONSTRAINT IF EXISTS club_activities_end_after_start_check
    """

    execute """
    CREATE INDEX IF NOT EXISTS user_profiles_first_name_last_name_index
      ON user_profiles (first_name, last_name)
    """

    execute """
    CREATE INDEX IF NOT EXISTS club_activity_registrations_status_index
      ON club_activity_registrations (status)
    """

    execute """
    CREATE INDEX IF NOT EXISTS club_activity_registrations_attendance_status_index
      ON club_activity_registrations (attendance_status)
    """

    execute """
    CREATE INDEX IF NOT EXISTS club_activity_registrations_attendance_marked_at_index
      ON club_activity_registrations (attendance_marked_at)
    """

    execute """
    CREATE INDEX IF NOT EXISTS club_activity_refunds_status_index
      ON club_activity_refunds (status)
    """

    execute """
    CREATE INDEX IF NOT EXISTS notifications_user_id_index
      ON notifications (principal_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS notifications_created_at_index
      ON notifications (created_at)
    """
  end
end
