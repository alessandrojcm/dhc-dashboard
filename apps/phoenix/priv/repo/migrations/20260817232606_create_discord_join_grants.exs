defmodule Dhc.Repo.Migrations.CreateDiscordJoinGrants do
  use Ecto.Migration

  def change do
    create table(:discord_join_grants, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :continuation_id,
          references(:invitation_acceptance_discord_continuations,
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :attempt_id,
          references(:invitation_acceptance_attempts, type: :uuid, on_delete: :restrict),
          null: false

      add :encrypted_access_token, :text
      add :expires_at, :timestamptz, null: false

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create unique_index(:discord_join_grants, [:continuation_id])
    create index(:discord_join_grants, [:attempt_id])
  end
end
