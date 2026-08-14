defmodule Dhc.Repo.Migrations.Ale220DiscordIdentityRecovery do
  use Ecto.Migration

  def up do
    alter table(:external_identities) do
      add(:sign_in_disabled_at, :timestamptz)
    end

    create table(:discord_identity_recovery_cases, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :external_identity_id,
        references(:external_identities, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:case_reference, :text, null: false)
      add(:state, :text, null: false, default: "open")
      add(:reason_code, :text, null: false)
      add(:reporter_reference, :text, null: false)
      add(:binding_fingerprint, :text, null: false)
      add(:evidence_references, {:array, :text}, null: false)

      add(:actor_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:opened_at, :timestamptz, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(unique_index(:discord_identity_recovery_cases, [:case_reference]))

    create(
      unique_index(:discord_identity_recovery_cases, [:external_identity_id],
        where: "state = 'open'",
        name: :discord_identity_recovery_cases_open_identity_unique
      )
    )

    create(
      constraint(:discord_identity_recovery_cases, :discord_identity_recovery_cases_state_check,
        check: "state = 'open'"
      )
    )

    create(
      constraint(:discord_identity_recovery_cases, :discord_identity_recovery_cases_reason_check,
        check: "reason_code IN ('promoted_binding', 'replacement_request')"
      )
    )

    create(
      constraint(
        :discord_identity_recovery_cases,
        :discord_identity_recovery_cases_evidence_check,
        check: "cardinality(evidence_references) BETWEEN 1 AND 10"
      )
    )

    create table(:discord_identity_recovery_audit_events, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :recovery_case_id,
        references(:discord_identity_recovery_cases, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:action, :text, null: false)

      add(:actor_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(index(:discord_identity_recovery_audit_events, [:recovery_case_id, :created_at]))

    create(
      constraint(
        :discord_identity_recovery_audit_events,
        :discord_identity_recovery_audit_events_action_check,
        check: "action = 'opened_and_contained'"
      )
    )

    execute("""
    CREATE FUNCTION ale220_reject_recovery_audit_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'identity recovery audit events are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'discord_identity_recovery_audit_events_immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ale220_reject_recovery_audit_mutation
      BEFORE UPDATE OR DELETE ON discord_identity_recovery_audit_events
      FOR EACH ROW EXECUTE FUNCTION ale220_reject_recovery_audit_mutation();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS ale220_reject_recovery_audit_mutation ON discord_identity_recovery_audit_events"
    )

    execute("DROP FUNCTION IF EXISTS ale220_reject_recovery_audit_mutation()")
    drop(table(:discord_identity_recovery_audit_events))
    drop(table(:discord_identity_recovery_cases))

    alter table(:external_identities) do
      remove(:sign_in_disabled_at)
    end
  end
end
