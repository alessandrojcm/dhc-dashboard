defmodule Dhc.Repo.Migrations.CreateTrainingAnnouncementTables do
  @moduledoc """
  ALE-322: own tables for `Dhc.TrainingAnnouncements`.

  Four tables, no references to `club_activities`:

  * `training_announcements` — the Training Announcement aggregate.
  * `training_announcement_suppressions` — absolute-date Suppressions.
  * `training_announcement_overrides` — absolute-date Overrides with a
    GiST exclusion so one announcement's ranges never overlap.
  * `discord_announcement_deliveries` — the Discord Announcement Delivery,
    subject `occurrence | holiday`, with partial unique indexes as the only
    duplicate fence and a CHECK tying the subject to its populated columns.
  """

  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist", "SELECT 1")

    create table(:training_announcements, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :kind, :text, null: false
      add :weekday, :smallint
      add :one_off_date, :date
      add :post_time, :time, null: false
      add :title, :text, null: false
      add :message, :text, null: false
      add :mention_everyone, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :retired, :boolean, null: false, default: false
      add :first_attempted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      constraint(:training_announcements, :training_announcements_kind_check,
        check: "kind IN ('roll_call', 'sparring')"
      )
    )

    create(
      constraint(:training_announcements, :training_announcements_weekday_check,
        check: "weekday IS NULL OR (weekday >= 1 AND weekday <= 7)"
      )
    )

    create(
      constraint(:training_announcements, :training_announcements_schedule_shape_check,
        check: "(weekday IS NULL) != (one_off_date IS NULL)"
      )
    )

    create(
      constraint(:training_announcements, :training_announcements_title_check,
        check: "char_length(title) > 0 AND char_length(title) <= 100"
      )
    )

    create(
      constraint(:training_announcements, :training_announcements_message_check,
        check: "char_length(message) > 0 AND char_length(message) <= 2000"
      )
    )

    create table(:training_announcement_suppressions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :announcement_id,
          references(:training_announcements, type: :binary_id, on_delete: :delete_all),
          null: false

      add :from_date, :date, null: false
      add :to_date, :date, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(index(:training_announcement_suppressions, [:announcement_id]))

    create(
      constraint(
        :training_announcement_suppressions,
        :training_announcement_suppressions_range_check, check: "from_date <= to_date")
    )

    create table(:training_announcement_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :announcement_id,
          references(:training_announcements, type: :binary_id, on_delete: :delete_all),
          null: false

      add :from_date, :date, null: false
      add :to_date, :date, null: false
      add :title, :text
      add :message, :text

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(index(:training_announcement_overrides, [:announcement_id]))

    create(
      constraint(:training_announcement_overrides, :training_announcement_overrides_range_check,
        check: "from_date <= to_date"
      )
    )

    create(
      constraint(:training_announcement_overrides, :training_announcement_overrides_content_check,
        check: "title IS NOT NULL OR message IS NOT NULL"
      )
    )

    execute(
      "ALTER TABLE training_announcement_overrides ADD CONSTRAINT training_announcement_overrides_no_overlap EXCLUDE USING gist (announcement_id WITH =, daterange(from_date, to_date, '[]') WITH &&)",
      "ALTER TABLE training_announcement_overrides DROP CONSTRAINT training_announcement_overrides_no_overlap"
    )

    create table(:discord_announcement_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :subject, :text, null: false

      add :announcement_id,
          references(:training_announcements, type: :binary_id, on_delete: :delete_all)

      add :occurrence_date, :date
      add :holiday_date, :date
      add :phase, :text

      add :post_time, :time
      add :kind, :text
      add :mention_everyone, :boolean
      add :title_source, :text
      add :message_source, :text
      add :rendered_message, :text
      add :thread_name, :text
      add :channel_id, :text

      add :state, :text, null: false
      add :reason, :text

      add :frozen_at, :utc_datetime_usec
      add :posting_started_at, :utc_datetime_usec
      add :message_posted_at, :utc_datetime_usec
      add :thread_created_at, :utc_datetime_usec
      add :concluded_at, :utc_datetime_usec

      add :discord_message_id, :text
      add :discord_thread_id, :text
      add :error_detail, :text
      add :thread_attempts, :integer, null: false, default: 0
      add :last_thread_error, :text

      add :applied_suppression_id,
          references(:training_announcement_suppressions,
            type: :binary_id,
            on_delete: :nilify_all
          )

      add :applied_override_id,
          references(:training_announcement_overrides, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(index(:discord_announcement_deliveries, [:announcement_id]))

    create(
      unique_index(:discord_announcement_deliveries, [:announcement_id, :occurrence_date],
        where: "subject = 'occurrence'",
        name: :discord_announcement_deliveries_occurrence_unique
      )
    )

    create(
      unique_index(:discord_announcement_deliveries, [:holiday_date, :phase],
        where: "subject = 'holiday'",
        name: :discord_announcement_deliveries_holiday_unique
      )
    )

    create(
      constraint(
        :discord_announcement_deliveries,
        :discord_announcement_deliveries_subject_shape_check,
        check:
          "(subject = 'occurrence' AND announcement_id IS NOT NULL AND occurrence_date IS NOT NULL AND holiday_date IS NULL AND phase IS NULL) OR " <>
            "(subject = 'holiday' AND announcement_id IS NULL AND occurrence_date IS NULL AND holiday_date IS NOT NULL AND phase IN ('day_before', 'same_day'))"
      )
    )

    create(
      constraint(:discord_announcement_deliveries, :discord_announcement_deliveries_state_check,
        check:
          "state IN ('frozen', 'posting_message', 'message_posted', 'creating_thread', 'delivered', 'message_uncertain', 'thread_failed', 'blocked', 'skipped', 'missed')"
      )
    )

    create(
      constraint(:discord_announcement_deliveries, :discord_announcement_deliveries_reason_check,
        check:
          "reason IS NULL OR reason IN ('holiday', 'disabled', 'suppressed', 'unconfigured_channel', 'invalid_copy', 'late', 'permission', 'unknown_channel', 'payload_rejected', 'timeout', 'server_error', 'worker_lost', 'unknown')"
      )
    )

    create(
      constraint(:discord_announcement_deliveries, :discord_announcement_deliveries_kind_check,
        check: "kind IS NULL OR kind IN ('roll_call', 'sparring')"
      )
    )

    create(
      constraint(
        :discord_announcement_deliveries,
        :discord_announcement_deliveries_thread_attempts_check, check: "thread_attempts >= 0")
    )
  end

  def down do
    drop(table(:discord_announcement_deliveries))
    drop(table(:training_announcement_overrides))
    drop(table(:training_announcement_suppressions))
    drop(table(:training_announcements))
  end
end
