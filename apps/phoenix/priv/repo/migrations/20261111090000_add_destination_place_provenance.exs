defmodule Dhc.Repo.Migrations.AddDestinationPlaceProvenance do
  @moduledoc """
  ALE-442: the provider identity of a destination staff deliberately selected
  from Google Maps venue search, in each Workshop domain's own table
  (ADR 0029: regular Workshops and Beginners' Workshops share no storage).

  Per the owner's ALE-439 decision (`docs/google-places-terms-validation.md`)
  only the Place ID, `provider: google` and an application-generated
  selection timestamp are kept — never Google's name, address or credits,
  raw responses, coordinates, photos, reviews or contact details. Directions
  links for a selected place are derived at read time, so no provider-derived
  link is stored.

  The provider, Place ID and selection timestamp are all set or all absent;
  a manual destination carries none of them.
  """

  use Ecto.Migration

  @tables [:club_activities, :beginners_workshops]

  def change do
    for table <- @tables do
      alter table(table) do
        add :destination_provider, :text
        add :destination_place_id, :text
        add :destination_selected_at, :utc_datetime
      end

      create(
        constraint(table, :"#{table}_destination_provider_known",
          check: "destination_provider IS NULL OR destination_provider = 'google'"
        )
      )

      create(
        constraint(table, :"#{table}_destination_place_complete",
          check:
            "(destination_provider IS NULL) = (destination_place_id IS NULL) AND " <>
              "(destination_place_id IS NULL) = (destination_selected_at IS NULL)"
        )
      )

      create(
        constraint(table, :"#{table}_destination_place_id_length",
          check: "char_length(destination_place_id) <= 255"
        )
      )
    end
  end
end
