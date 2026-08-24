defmodule Dhc.Repo.Migrations.BackfillUserProfilePronounsToEmptyString do
  use Ecto.Migration

  @moduledoc """
  Pronouns collection is optional as of this change, so "not disclosed" gets
  one canonical representation: the empty string.

  - Backfills existing NULL `user_profiles.pronouns` values to `''`.
  - Adds an `''` column default so future inserts that never collect pronouns
    (e.g. direct-invitation profiles) stay consistent.

  Uses `SET DEFAULT` rather than `Ecto.Migration.modify/3`: production carries
  the legacy `member_management_view`, and Postgres rejects any `ALTER COLUMN
  ... TYPE` on a view-referenced column (`feature_not_supported`). The column
  is already nullable `text`, so no type change is needed anyway.
  """

  def up do
    execute "ALTER TABLE user_profiles ALTER COLUMN pronouns SET DEFAULT ''"

    execute "UPDATE user_profiles SET pronouns = '' WHERE pronouns IS NULL"
  end

  def down do
    execute "ALTER TABLE user_profiles ALTER COLUMN pronouns SET DEFAULT NULL"
  end
end
