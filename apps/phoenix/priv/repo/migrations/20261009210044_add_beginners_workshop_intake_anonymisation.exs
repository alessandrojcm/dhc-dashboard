defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopIntakeAnonymisation do
  @moduledoc """
  ALE-396 (spec stories 119 and 120): a person's hard delete — the retention
  purge or a coordinator's manual delete — anonymises their Intakes instead
  of deleting them, so reporting still adds up.

  Additive. An anonymised Intake has no person (`waitlist_id` null, which
  the existing `ON DELETE SET NULL` foreign key already allows) and records
  when it was anonymised. Its queue date stays. An `attended` Intake first
  records whether the person had gone on to be invited or to join
  (`invitation_outcome`: `not_invited`, `invited` or `joined`), the fact the
  Invitation handoff held on their Waitlist standing, which the delete
  removes.

  The Carried Fee keeps its row with no person (its `waitlist_id` foreign
  key is already nullable and `ON DELETE SET NULL`), and refund rows never
  referenced the person, so refund history survives as it is.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshop_intakes) do
      add :anonymised_at, :utc_datetime_usec
      add :invitation_outcome, :text
    end

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_anonymised_check,
        check: "anonymised_at IS NULL OR waitlist_id IS NULL"
      )
    )

    create(
      constraint(
        :beginners_workshop_intakes,
        :beginners_workshop_intakes_invitation_outcome_check,
        check:
          "invitation_outcome IS NULL OR " <>
            "(anonymised_at IS NOT NULL AND " <>
            "invitation_outcome IN ('not_invited', 'invited', 'joined'))"
      )
    )
  end
end
