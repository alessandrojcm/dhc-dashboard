defmodule Dhc.Repo.Migrations.AddWorkshopDestinations do
  @moduledoc """
  ALE-440: optional, manually entered destination details on regular Workshops.

  Additive and fully nullable so legacy rows and label-only submissions stay
  valid: the required short venue label (`location`) is unchanged and stays
  independent of these columns. No Google-derived persistence — these hold
  only manually supplied text and an optional manually supplied Maps link.

  The Calendar projection derives its native location string from the
  name/address here, falling back to `location`.
  """

  use Ecto.Migration

  def change do
    alter table(:club_activities) do
      add :destination_name, :text
      add :destination_address, :text
      add :directions_url, :text
    end

    # `char_length(NULL)` is NULL, which passes a CHECK, so legacy rows and
    # cleared destinations satisfy every constraint. The same limits are
    # enforced on the changeset for field errors; these guard out-of-seam
    # writers.
    create(
      constraint(:club_activities, :club_activities_destination_name_length,
        check: "char_length(destination_name) <= 255"
      )
    )

    create(
      constraint(:club_activities, :club_activities_destination_address_length,
        check: "char_length(destination_address) <= 500"
      )
    )

    create(
      constraint(:club_activities, :club_activities_directions_url_length,
        check: "char_length(directions_url) <= 2048"
      )
    )
  end
end
