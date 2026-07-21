defmodule Dhc.Repo.Migrations.Ale163M2CutOverAuthenticationAuthority do
  use Ecto.Migration

  @moduledoc """
  ALE-163 M2: under the maintenance write freeze, revalidate M1 and move all
  application ownership constraints and names from Supabase Auth to Principals.
  """

  def up, do: Dhc.AuthMigration.M2.run!(repo())

  def down, do: Dhc.AuthMigration.M2.rollback!(repo())
end
