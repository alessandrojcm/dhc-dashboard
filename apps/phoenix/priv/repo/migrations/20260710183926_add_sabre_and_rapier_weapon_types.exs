defmodule Dhc.Repo.Migrations.AddSabreAndRapierWeaponTypes do
  use Ecto.Migration

  def up do
    execute "ALTER TYPE preferred_weapon ADD VALUE IF NOT EXISTS 'sabre'"
    execute "ALTER TYPE preferred_weapon ADD VALUE IF NOT EXISTS 'rapier'"
  end

  def down do
    # Postgres does not support removing individual values from an enum.
    # Reverting would require dropping and recreating the type, which is
    # destructive if any rows reference the values. The down is a no-op;
    # if a true rollback is needed, it must be done manually.
    :ok
  end
end
