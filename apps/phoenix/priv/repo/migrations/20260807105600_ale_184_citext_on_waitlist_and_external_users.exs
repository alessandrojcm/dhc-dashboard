defmodule Dhc.Repo.Migrations.Ale184CitextOnWaitlistAndExternalUsers do
  use Ecto.Migration

  def up do
    # ALE-178 owns the invitations.email citext cast.
    execute "ALTER TABLE waitlist ALTER COLUMN email TYPE citext USING email::citext"

    execute "ALTER TABLE external_users ALTER COLUMN email TYPE citext USING email::citext"
  end

  def down do
    execute "ALTER TABLE external_users ALTER COLUMN email TYPE text USING email::text"

    execute "ALTER TABLE waitlist ALTER COLUMN email TYPE text USING email::text"
  end
end
