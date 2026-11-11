defmodule Dhc.Repo.Migrations.AddWorkshopDestinations do
  @moduledoc """
  ALE-440: optional, manually entered destination text on regular Workshops —
  what staff typed in the destination input without choosing a suggestion.

  Additive and nullable so legacy rows and label-only submissions stay valid:
  the required short venue label (`location`) is unchanged and stays
  independent of this column. No Google-derived persistence — this holds only
  staff-typed text.

  The Calendar projection uses this text as its native location string,
  falling back to `location`.
  """

  use Ecto.Migration

  def change do
    alter table(:club_activities) do
      add :destination_text, :text
    end

    # `char_length(NULL)` is NULL, which passes a CHECK, so legacy rows and
    # cleared destinations satisfy it. The changeset enforces the same limit
    # for a field error; this guards out-of-seam writers.
    create(
      constraint(:club_activities, :club_activities_destination_text_length,
        check: "char_length(destination_text) <= 500"
      )
    )
  end
end
