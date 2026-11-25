defmodule Dhc.Repo.Migrations.AddReOfferIntakeOrigin do
  @moduledoc """
  A Re-offer (`CONTEXT.md`) creates a new `contacted` Intake for a person
  whose earlier Intake for the same Beginners' Workshop lapsed or was
  returned. Its origin is `re_offer`, which, like `fast_track`, has no Batch.

  The origin check is replaced, not loosened: `batch` still requires a
  Batch, and the two staff origins still forbid one. Existing rows are
  unaffected.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_origin_check))

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_origin_check,
        check:
          "(origin = 'batch' AND batch_id IS NOT NULL) OR (origin IN ('fast_track', 're_offer') AND batch_id IS NULL)"
      )
    )
  end

  def down do
    drop(constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_origin_check))

    create(
      constraint(:beginners_workshop_intakes, :beginners_workshop_intakes_origin_check,
        check:
          "(origin = 'batch' AND batch_id IS NOT NULL) OR (origin = 'fast_track' AND batch_id IS NULL)"
      )
    )
  end
end
