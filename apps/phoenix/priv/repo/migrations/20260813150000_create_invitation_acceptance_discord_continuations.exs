defmodule Dhc.Repo.Migrations.CreateInvitationAcceptanceDiscordContinuations do
  use Ecto.Migration

  def change do
    create table(:invitation_acceptance_discord_continuations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :invitation_id, references(:invitations, type: :uuid, on_delete: :restrict), null: false

      add :attempt_id,
          references(:invitation_acceptance_attempts, type: :uuid, on_delete: :restrict),
          null: false

      add :status, :text, null: false, default: "awaiting_oauth"
      add :expires_at, :timestamptz, null: false
      add :concluded_at, :timestamptz

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:invitation_acceptance_discord_continuations, [:attempt_id])

    execute(
      """
      CREATE UNIQUE INDEX invitation_acceptance_discord_continuations_live_attempt_unique
        ON invitation_acceptance_discord_continuations (attempt_id)
        WHERE status IN ('awaiting_oauth', 'verified')
      """,
      "DROP INDEX invitation_acceptance_discord_continuations_live_attempt_unique"
    )

    create constraint(
             :invitation_acceptance_discord_continuations,
             :invitation_acceptance_discord_continuations_status_check,
             check:
               "status IN ('awaiting_oauth', 'verified', 'consumed', 'expired', 'cancelled', 'collision', 'failed')"
           )
  end
end
