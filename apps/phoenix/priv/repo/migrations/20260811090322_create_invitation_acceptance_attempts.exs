defmodule Dhc.Repo.Migrations.CreateInvitationAcceptanceAttempts do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE UNIQUE INDEX invitations_issue_key_unique
        ON invitations ((metadata->>'issue_key'))
        WHERE metadata ? 'issue_key'
      """,
      "DROP INDEX invitations_issue_key_unique"
    )

    create table(:invitation_acceptance_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :invitation_id, references(:invitations, type: :uuid, on_delete: :restrict), null: false
      add :status, :text, null: false, default: "processing"
      add :acceptance_data, :map, null: false
      add :stripe_customer_id, :text
      add :stripe_state, :map, null: false, default: fragment("'{}'::jsonb")
      add :last_error, :text
      add :concluded_at, :timestamptz

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:invitation_acceptance_attempts, [:invitation_id])
    create index(:invitation_acceptance_attempts, [:status])

    execute(
      """
      CREATE UNIQUE INDEX invitation_acceptance_attempts_active_unique
        ON invitation_acceptance_attempts (invitation_id)
        WHERE status IN ('processing', 'cleanup_pending', 'provisioned')
      """,
      "DROP INDEX invitation_acceptance_attempts_active_unique"
    )

    create constraint(
             :invitation_acceptance_attempts,
             :invitation_acceptance_attempts_status_check,
             check:
               "status IN ('processing', 'cleanup_pending', 'provisioned', 'completed', 'declined')"
           )

    create constraint(
             :invitation_acceptance_attempts,
             :invitation_acceptance_attempts_conclusion_check,
             check: "(status IN ('completed', 'declined')) = (concluded_at IS NOT NULL)"
           )
  end
end
