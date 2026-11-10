defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopDestinations do
  @moduledoc """
  ALE-441: optional, manually entered destination details on Beginners'
  Workshops — the regular Workshop columns of ALE-440, in this domain's own
  table (ADR 0029: the two share no storage).

  Additive and fully nullable so legacy rows and label-only submissions stay
  valid: the required short `venue` label keeps its 80-character `{{venue}}`
  placeholder maximum and stays independent of these columns. No
  Google-derived persistence — only manually supplied text and an optional
  manually supplied Maps link. The Calendar projection derives its native
  location from the name/address here, falling back to `venue`.
  """

  use Ecto.Migration

  def change do
    alter table(:beginners_workshops) do
      add :destination_name, :text
      add :destination_address, :text
      add :directions_url, :text
    end

    # `char_length(NULL)` is NULL, which passes a CHECK, so legacy rows and
    # cleared destinations satisfy every constraint. The changeset enforces
    # the same limits for field errors; these guard out-of-seam writers.
    create(
      constraint(:beginners_workshops, :beginners_workshops_destination_name_length,
        check: "char_length(destination_name) <= 255"
      )
    )

    create(
      constraint(:beginners_workshops, :beginners_workshops_destination_address_length,
        check: "char_length(destination_address) <= 500"
      )
    )

    create(
      constraint(:beginners_workshops, :beginners_workshops_directions_url_length,
        check: "char_length(directions_url) <= 2048"
      )
    )
  end
end
