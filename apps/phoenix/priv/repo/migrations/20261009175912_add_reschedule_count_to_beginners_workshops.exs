defmodule Dhc.Repo.Migrations.AddRescheduleCountToBeginnersWorkshops do
  @moduledoc """
  ALE-394: how many times a Beginners' Workshop has been rescheduled.

  Additive. The count names each reschedule: its "Workshop rescheduled"
  Intake Email log occasion (`rescheduled:<n>`), its keyed Staff
  Notification, and the Pre-workshop info occasion owed under the current
  schedule (`pre_workshop` for the original schedule, `pre_workshop:<n>`
  after the n-th reschedule), so a reschedule re-arms Pre-workshop info
  without deleting the ledger rows that record what was sent.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshops) do
      add :reschedule_count, :integer, null: false, default: 0
    end

    create(
      constraint(:beginners_workshops, :beginners_workshops_reschedule_count_check,
        check: "reschedule_count >= 0"
      )
    )
  end
end
