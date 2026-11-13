defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopDestinations do
  @moduledoc """
  ALE-441: optional, manually entered destination text on Beginners'
  Workshops — the regular Workshop column of ALE-440, in this domain's own
  table (ADR 0029: the two share no storage).

  Additive and nullable so legacy rows and label-only submissions stay valid:
  the required short `venue` label keeps its 80-character `{{venue}}`
  placeholder maximum and stays independent of this column. No Google-derived
  persistence — only staff-typed text. The Calendar projection uses it as its
  native location, falling back to `venue`.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshops) do
      add :destination_text, :text
    end

    # `char_length(NULL)` is NULL, which passes a CHECK, so legacy rows and
    # cleared destinations satisfy it. The changeset enforces the same limit
    # for a field error; this guards out-of-seam writers.
    create(
      constraint(:beginners_workshops, :beginners_workshops_destination_text_length,
        check: "char_length(destination_text) <= 500"
      )
    )
  end
end
