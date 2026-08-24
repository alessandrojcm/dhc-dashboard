defmodule Dhc.Repo.Migrations.BackfillUserProfilePronounsToEmptyString do
  use Ecto.Migration

  @moduledoc """
  Pronouns collection is optional as of this change, so "not disclosed" gets
  one canonical representation: the empty string.

  - Backfills existing NULL `user_profiles.pronouns` values to `''`.
  - Adds an `''` column default so future inserts that never collect pronouns
    (e.g. direct-invitation profiles) stay consistent.
  """

  def up do
    alter table(:user_profiles) do
      modify :pronouns, :text, null: true, default: ""
    end

    execute "UPDATE user_profiles SET pronouns = '' WHERE pronouns IS NULL"
  end

  def down do
    alter table(:user_profiles) do
      modify :pronouns, :text, null: true, default: nil
    end
  end
end
