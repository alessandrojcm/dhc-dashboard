defmodule Dhc.Repo.Migrations.Ale166M1PopulatePrincipalIdentities do
  use Ecto.Migration

  @moduledoc """
  ALE-166 M1: additively populate Phoenix Principals and Discord External
  Identities while Supabase Auth remains live.

  All validation and DML lives in `Dhc.AuthMigration.M1`, which is invoked
  here inside Ecto's normal transactional migration boundary and directly by
  the restored-backup rehearsal tests through the SQL sandbox.

  This migration does not rename columns or repoint application foreign keys;
  those changes belong to M2 / ALE-163 under the cutover write freeze.
  """

  def up, do: Dhc.AuthMigration.M1.run!(repo())

  def down, do: Dhc.AuthMigration.M1.rollback!(repo())
end
