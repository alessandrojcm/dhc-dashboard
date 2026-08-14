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
        :discord_identity_recovery_cases_fingerprint_check,
        check: "binding_fingerprint ~ '^[0-9a-f]{64}$'"
      )
    )

    create(
      constraint(
        :discord_identity_recovery_cases,
        :discord_identity_recovery_cases_reporter_reference_check,
        check: "reporter_reference ~ '^(support-case|ticket):[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'"
      )
    )

    execute("""
    CREATE FUNCTION ale220_valid_evidence_references(evidence_refs text[]) RETURNS boolean AS $$
      SELECT cardinality(evidence_refs) BETWEEN 1 AND 10
        AND NOT EXISTS (
          SELECT 1 FROM unnest(evidence_refs) AS reference
          WHERE reference !~ '^(evidence|attachment|ticket):[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'
        );
    $$ LANGUAGE sql IMMUTABLE STRICT;
    """)

    create(
      constraint(
        :discord_identity_recovery_cases,
        :discord_identity_recovery_cases_evidence_check,
        check: "ale220_valid_evidence_references(evidence_references)"
      )
    )

    create table(:discord_identity_recovery_operator_proof_uses, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:proof_digest, :text, null: false)
      add(:manifest_digest, :text, null: false)

      add(:actor_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :recovery_case_id,
        references(:discord_identity_recovery_cases, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:consumed_at, :timestamptz, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(unique_index(:discord_identity_recovery_operator_proof_uses, [:proof_digest]))

    create(
      constraint(
        :discord_identity_recovery_operator_proof_uses,
        :discord_identity_recovery_operator_proof_uses_digest_check,
        check: "proof_digest ~ '^[0-9a-f]{64}$' AND manifest_digest ~ '^[0-9a-f]{64}$'"
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
    create(unique_index(:discord_identity_recovery_audit_events, [:recovery_case_id, :action]))

    create(
      constraint(
        :discord_identity_recovery_audit_events,
        :discord_identity_recovery_audit_events_action_check,
        check: "action = 'opened_and_contained'"
      )
    )

    execute("""
    CREATE FUNCTION ale220_reject_recovery_case_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'identity recovery cases are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'discord_identity_recovery_cases_immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ale220_reject_recovery_case_mutation
      BEFORE UPDATE OR DELETE ON discord_identity_recovery_cases
      FOR EACH ROW EXECUTE FUNCTION ale220_reject_recovery_case_mutation();
    """)

    execute("""
    CREATE FUNCTION ale220_append_recovery_open_audit() RETURNS trigger AS $$
    BEGIN
      INSERT INTO discord_identity_recovery_audit_events
        (id, recovery_case_id, action, actor_principal_id, created_at)
      VALUES
        (gen_random_uuid(), NEW.id, 'opened_and_contained', NEW.actor_principal_id, NEW.created_at);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ale220_append_recovery_open_audit
      AFTER INSERT ON discord_identity_recovery_cases
      FOR EACH ROW EXECUTE FUNCTION ale220_append_recovery_open_audit();
    """)

    execute("""
    CREATE FUNCTION ale220_guard_recovery_audit_write() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'INSERT' AND pg_trigger_depth() > 1 THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'identity recovery audit events are database-managed and immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'discord_identity_recovery_audit_events_immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ale220_guard_recovery_audit_write
      BEFORE INSERT OR UPDATE OR DELETE ON discord_identity_recovery_audit_events
      FOR EACH ROW EXECUTE FUNCTION ale220_guard_recovery_audit_write();
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS ale220_guard_recovery_audit_write ON discord_identity_recovery_audit_events"
    )

    execute("DROP FUNCTION IF EXISTS ale220_guard_recovery_audit_write()")

    execute(
      "DROP TRIGGER IF EXISTS ale220_append_recovery_open_audit ON discord_identity_recovery_cases"
    )

    execute("DROP FUNCTION IF EXISTS ale220_append_recovery_open_audit()")

    execute(
      "DROP TRIGGER IF EXISTS ale220_reject_recovery_case_mutation ON discord_identity_recovery_cases"
    )

    execute("DROP FUNCTION IF EXISTS ale220_reject_recovery_case_mutation()")
    drop(table(:discord_identity_recovery_audit_events))
    drop(table(:discord_identity_recovery_operator_proof_uses))
    drop(table(:discord_identity_recovery_cases))
    execute("DROP FUNCTION IF EXISTS ale220_valid_evidence_references(text[])")

    alter table(:external_identities) do
      remove(:sign_in_disabled_at)
    end
  end
end
