defmodule Dhc.Repo.Migrations.Ale216CreateDiscordRosterReceipts do
  use Ecto.Migration

  def change do
    create table(:discord_roster_executions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :actor_id, references(:principals, type: :uuid, on_delete: :restrict), null: false

      add :guild_id, :text, null: false
      add :bot_application_id, :text, null: false
      add :tool_revision, :text, null: false
      add :status, :text, null: false, default: "approved"
      add :approved_at, :timestamptz, null: false
      add :expires_at, :timestamptz, null: false
      add :started_at, :timestamptz
      add :finished_at, :timestamptz

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:discord_roster_executions, [:actor_id])
    create index(:discord_roster_executions, [:expires_at])

    create constraint(:discord_roster_executions, :discord_roster_executions_status_check,
             check: "status IN ('approved', 'running', 'succeeded', 'failed')"
           )

    create constraint(
             :discord_roster_executions,
             :discord_roster_executions_lifecycle_check,
             check:
               "(status = 'approved' AND started_at IS NULL AND finished_at IS NULL) OR " <>
                 "(status = 'running' AND started_at IS NOT NULL AND finished_at IS NULL) OR " <>
                 "(status IN ('succeeded', 'failed') AND started_at IS NOT NULL AND finished_at IS NOT NULL)"
           )

    create table(:discord_roster_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :kind, :text, null: false
      add :status, :text, null: false

      add :execution_id,
          references(:discord_roster_executions, type: :uuid, on_delete: :restrict),
          null: false

      add :actor_id, references(:principals, type: :uuid, on_delete: :restrict), null: false
      add :guild_id, :text, null: false
      add :bot_application_id, :text, null: false
      add :observed_bot_application_id, :text
      add :tool_revision, :text, null: false
      add :evidence_digest, :text, null: false
      add :package_digest, :text
      add :record_count, :integer
      add :result, :text, null: false

      add :preflight_receipt_id,
          references(:discord_roster_receipts, type: :uuid, on_delete: :restrict)

      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create index(:discord_roster_receipts, [:execution_id])
    create index(:discord_roster_receipts, [:actor_id])
    create index(:discord_roster_receipts, [:preflight_receipt_id])
    create index(:discord_roster_receipts, [:created_at])

    create constraint(:discord_roster_receipts, :discord_roster_receipts_kind_check,
             check: "kind IN ('preflight', 'capture')"
           )

    create constraint(:discord_roster_receipts, :discord_roster_receipts_status_check,
             check: "status IN ('succeeded', 'failed')"
           )

    create constraint(:discord_roster_receipts, :discord_roster_receipts_capture_fields_check,
             check:
               "(kind = 'preflight' AND package_digest IS NULL AND preflight_receipt_id IS NULL) OR " <>
                 "(kind = 'capture' AND package_digest IS NOT NULL AND record_count IS NOT NULL AND preflight_receipt_id IS NOT NULL)"
           )
  end
end
