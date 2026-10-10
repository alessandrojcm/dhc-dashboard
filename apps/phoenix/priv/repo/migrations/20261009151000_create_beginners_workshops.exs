defmodule Dhc.Repo.Migrations.CreateBeginnersWorkshops do
  @moduledoc """
  ALE-378 (ADR 0029): the first table of `Dhc.BeginnersWorkshops`.

  Additive. A Beginners' Workshop is not a Workshop and has no reference to
  `club_activities` or any `club_activity_*` table. Its civil date and start
  time are Europe/Dublin; the Payment Cutoff is the instant they resolve to.
  The fee is an integer in cents with no currency column (ADR 0029).
  Later tickets add Staff, Batches, Intakes and payments as their own tables.
  """

  use Ecto.Migration

  def change do
    create table(:beginners_workshops, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :status, :text, null: false, default: "scheduled"
      add :venue, :text, null: false
      add :date, :date, null: false
      add :start_time, :time, null: false
      add :capacity, :integer, null: false
      add :fee_cents, :integer, null: false
      add :payment_cutoff, :utc_datetime_usec, null: false
      add :contact_from, :date, null: false
      add :payment_window_days, :integer, null: false

      add :scheduled_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(index(:beginners_workshops, [:date]))

    create(
      constraint(:beginners_workshops, :beginners_workshops_status_check,
        check: "status IN ('scheduled', 'finalised', 'cancelled')"
      )
    )

    create(
      constraint(:beginners_workshops, :beginners_workshops_venue_check,
        check: "char_length(venue) > 0 AND char_length(venue) <= 80"
      )
    )

    create(
      constraint(:beginners_workshops, :beginners_workshops_capacity_check, check: "capacity > 0")
    )

    create(
      constraint(:beginners_workshops, :beginners_workshops_fee_check, check: "fee_cents > 0")
    )

    create(
      constraint(:beginners_workshops, :beginners_workshops_payment_window_check,
        check: "payment_window_days >= 1"
      )
    )
  end
end
