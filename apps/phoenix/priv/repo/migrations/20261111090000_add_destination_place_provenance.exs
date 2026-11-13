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

  The provider, Place ID and selection timestamp are all set or all absent,
  and a selected place carries no manual `destination_text`: a destination
  is a place or text, never both (`Dhc.Destinations.validate_changeset/2`
  enforces the same rule for a field error).
  """

  use Ecto.Migration

  @tables [:club_activities, :beginners_workshops]

  def change do
    for table <- @tables do
      # Repair: older databases may be missing the `destination_text` column
      # that ALE-440/ALE-441 added (the provenance constraint references it).
      execute("""
      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = '#{table}' AND column_name = 'destination_text'
        ) THEN
          ALTER TABLE "#{table}" ADD COLUMN destination_text text;
        END IF;
      END $$;
      """)

      # Add the provenance columns if they are not already present, so a
      # partially-applied migration can be re-run safely.
      for column <- [:destination_provider, :destination_place_id, :destination_selected_at] do
        type =
          case column do
            :destination_selected_at -> "timestamp without time zone"
            _ -> "text"
          end

        execute("""
        DO $$ BEGIN
          IF NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = '#{table}' AND column_name = '#{column}'
          ) THEN
            ALTER TABLE "#{table}" ADD COLUMN "#{column}" #{type};
          END IF;
        END $$;
        """)
      end

      # Constraints, guarded so re-runs do not fail on existing objects.
      execute("""
      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint WHERE conname = '#{table}_destination_provider_known'
        ) THEN
          ALTER TABLE "#{table}" ADD CONSTRAINT "#{table}_destination_provider_known"
            CHECK (destination_provider IS NULL OR destination_provider = 'google');
        END IF;
      END $$;
      """)

      execute("""
      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint WHERE conname = '#{table}_destination_place_complete'
        ) THEN
          ALTER TABLE "#{table}" ADD CONSTRAINT "#{table}_destination_place_complete"
            CHECK (
              (destination_provider IS NULL) = (destination_place_id IS NULL) AND
              (destination_place_id IS NULL) = (destination_selected_at IS NULL)
            );
        END IF;
      END $$;
      """)

      execute("""
      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint WHERE conname = '#{table}_destination_text_or_place'
        ) THEN
          ALTER TABLE "#{table}" ADD CONSTRAINT "#{table}_destination_text_or_place"
            CHECK (destination_text IS NULL OR destination_place_id IS NULL);
        END IF;
      END $$;
      """)

      execute("""
      DO $$ BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM pg_constraint WHERE conname = '#{table}_destination_place_id_length'
        ) THEN
          ALTER TABLE "#{table}" ADD CONSTRAINT "#{table}_destination_place_id_length"
            CHECK (char_length(destination_place_id) <= 255);
        END IF;
      END $$;
      """)
    end
  end
end