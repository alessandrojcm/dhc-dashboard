defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshopBatchesAndIntakes do
  @moduledoc """
  ALE-380 (ADR 0029): automatic Batches, Intakes and the Intake Email log.

  Additive. A Batch is one automatic contact round of a Beginners' Workshop;
  an Intake is one person's place in one workshop. An Intake references the
  Waitlist person and stores no copy of them (anonymisation nulls the
  reference). Its capability link is rebuilt from the Intake id and link
  generation; only the token's hash is stored.

  The Intake Email log records which Intake Emails were queued, one row per
  occasion; its uniqueness keeps each scheduled email exactly-once.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshops) do
      add :batches_paused, :boolean, null: false, default: false
      add :batches_paused_at, :utc_datetime_usec

      add :batches_paused_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :nilify_all)

      add :batches_resumed_at, :utc_datetime_usec

      add :batches_resumed_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :nilify_all)
    end

    create table(:beginners_workshop_batches, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workshop_id, references(:beginners_workshops, type: :binary_id, on_delete: :restrict),
        null: false

      add :number, :integer, null: false
      add :size, :integer, null: false
      add :sent_at, :utc_datetime_usec, null: false
      add :window_ends_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create(
      unique_index(:beginners_workshop_batches, [:workshop_id, :number],
        name: :beginners_workshop_batches_number_index
      )
    )

    create(
      constraint(:beginners_workshop_batches, :beginners_workshop_batches_number_check,
        check: "number >= 1"
      )
    )

    create(
      constraint(:beginners_workshop_batches, :beginners_workshop_batches_size_check,
        check: "size >= 1"
      )
    )

    create(
      constraint(:beginners_workshop_batches, :beginners_workshop_batches_window_check,
        check: "window_ends_at > sent_at"
      )
    )

    create table(:beginners_workshop_intakes, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workshop_id, references(:beginners_workshops, type: :binary_id, on_delete: :restrict),
        null: false

      # Anonymisation (the retention purge) nulls the person reference.
      add :waitlist_id, references(:waitlist, type: :binary_id, on_delete: :nilify_all)
      add :state, :text, null: false, default: "contacted"
      add :origin, :text, null: false

      add :batch_id,
          references(:beginners_workshop_batches, type: :binary_id, on_delete: :restrict)

      # The person's priority date when they were drafted.
      add :queue_date, :utc_datetime, null: false
      add :link_generation, :integer, null: false, default: 1
      add :link_token_hash, :binary, null: false
      add :contacted_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(index(:beginners_workshop_intakes, [:workshop_id]))
    create(index(:beginners_workshop_intakes, [:batch_id]))

    create(
      unique_index(:beginners_workshop_intakes, [:link_token_hash],
        name: :beginners_workshop_intakes_link_token_hash_index
      )
    )

    # A person has at most one open Intake.
    create(
      unique_index(:beginners_workshop_intakes, [:waitlist_id],
        where: "state IN ('contacted', 'paid')",
        name: :beginners_workshop_intakes_one_open_per_person_index
      )
    )

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_state_check,
        check:
          "state IN ('contacted', 'paid', 'attended', 'no_show', 'lapsed', 'declined', 'returned', 'deferred', 'cancelled_refunded', 'withdrawn')"
      )
    )

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_origin_check,
        check:
          "(origin = 'batch' AND batch_id IS NOT NULL) OR (origin = 'fast_track' AND batch_id IS NULL)"
      )
    )

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_link_generation_check,
        check: "link_generation >= 1"
      )
    )

    create table(:beginners_workshop_intake_emails, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :intake_id,
          references(:beginners_workshop_intakes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :email_type, :text, null: false
      # Names the logical sending ("contact" for the Batch contact email);
      # unique per Intake.
      add :occasion, :text, null: false
      add :queued_at, :utc_datetime_usec, null: false
    end

    create(
      unique_index(:beginners_workshop_intake_emails, [:intake_id, :occasion],
        name: :beginners_workshop_intake_emails_occasion_index
      )
    )
  end
end
