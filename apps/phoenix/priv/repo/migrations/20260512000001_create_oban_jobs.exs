defmodule Dhc.Repo.Migrations.CreateObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migrations.up(prefix: "public")

    # The historical baseline below predates Phoenix-owned authentication and
    # references Supabase's auth tables. Keep an empty, source-compatible
    # surface so the complete history can run against a new PostgreSQL
    # instance. IF NOT EXISTS leaves an existing Supabase Auth installation
    # untouched; later migrations remove application FKs to these tables.
    execute "CREATE SCHEMA IF NOT EXISTS auth"

    execute """
    CREATE TABLE IF NOT EXISTS auth.users (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      aud text,
      role text,
      email text,
      confirmed_at timestamptz,
      created_at timestamptz,
      updated_at timestamptz
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS auth.identities (
      provider_id text NOT NULL,
      user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
      identity_data jsonb NOT NULL,
      provider text NOT NULL,
      last_sign_in_at timestamptz,
      created_at timestamptz,
      updated_at timestamptz,
      email text GENERATED ALWAYS AS (lower(identity_data ->> 'email')) STORED,
      id uuid PRIMARY KEY,
      CONSTRAINT identities_provider_id_provider_unique UNIQUE (provider_id, provider)
    )
    """

    execute "ALTER TABLE auth.identities ALTER COLUMN id SET DEFAULT gen_random_uuid()"
    execute "CREATE INDEX IF NOT EXISTS identities_user_id_idx ON auth.identities (user_id)"
  end

  def down do
    Oban.Migrations.down(prefix: "public")
  end
end
