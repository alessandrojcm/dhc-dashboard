defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopCancellation do
  @moduledoc """
  ALE-395: cancelling a Beginners' Workshop.

  Additive. `cancelled_at` records when the club cancelled the workshop,
  `cancelled_by_principal_id` who did, and `cancel_reason` the optional
  reason the coordinator gave (also kept on each Intake's history row).
  They are written only by `Dhc.BeginnersWorkshops.Commands`
  (`cancel_workshop`) together with `status = 'cancelled'`.
  """

  use Ecto.Migration

  def up do
    alter table(:beginners_workshops) do
      add :cancelled_at, :utc_datetime_usec

      add :cancelled_by_principal_id,
          references(:principals, type: :binary_id, on_delete: :restrict)

      add :cancel_reason, :text
    end

    # A workshop cancelled before this column existed (none in production)
    # records the time of its last change.
    execute("""
    UPDATE beginners_workshops SET cancelled_at = updated_at
    WHERE status = 'cancelled' AND cancelled_at IS NULL
    """)

    create(
      constraint(:beginners_workshops, :beginners_workshops_cancelled_check,
        check: "(status = 'cancelled') = (cancelled_at IS NOT NULL)"
      )
    )

    create(
      constraint(:beginners_workshops, :beginners_workshops_cancel_reason_check,
        check: "cancel_reason IS NULL OR char_length(cancel_reason) BETWEEN 1 AND 500"
      )
    )
  end

  def down do
    drop(constraint(:beginners_workshops, :beginners_workshops_cancel_reason_check))
    drop(constraint(:beginners_workshops, :beginners_workshops_cancelled_check))

    alter table(:beginners_workshops) do
      remove :cancel_reason
      remove :cancelled_by_principal_id
      remove :cancelled_at
    end
  end
end
