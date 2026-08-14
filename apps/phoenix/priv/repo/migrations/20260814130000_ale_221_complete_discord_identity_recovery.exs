defmodule Dhc.Repo.Migrations.Ale221CompleteDiscordIdentityRecovery do
  use Ecto.Migration

  def up do
    alter table(:external_identities) do
      add(:retired_at, :timestamptz)
    end

    drop_if_exists(
      unique_index(:external_identities, [:provider, :provider_subject],
        name: "unique_external_identities_provider_subject"
      )
    )

    drop_if_exists(
      unique_index(:external_identities, [:principal_id, :provider],
        name: "unique_external_identities_principal_provider"
      )
    )

    create(
      unique_index(:external_identities, [:provider, :provider_subject],
        where: "retired_at IS NULL",
        name: "unique_external_identities_provider_subject"
      )
    )

    create(
      unique_index(:external_identities, [:principal_id, :provider],
        where: "retired_at IS NULL",
        name: "unique_external_identities_principal_provider"
      )
    )

    alter table(:discord_identity_recovery_cases) do
      add(:destination_principal_id, references(:principals, type: :uuid, on_delete: :restrict))
      add(:incoming_subject_fingerprint, :text)
      add(:operation, :text)
      add(:completed_at, :timestamptz)
    end

    execute(
      "ALTER TABLE discord_identity_recovery_cases DROP CONSTRAINT discord_identity_recovery_cases_state_check"
    )

    create(
      constraint(:discord_identity_recovery_cases, :discord_identity_recovery_cases_state_check,
        check: "state IN ('open', 'completed', 'failed', 'cancelled', 'expired')"
      )
    )

    create(
      constraint(
        :discord_identity_recovery_cases,
        :discord_identity_recovery_cases_completion_check,
        check: """
        state <> 'completed'
        OR
        (destination_principal_id IS NOT NULL AND incoming_subject_fingerprint IS NOT NULL AND operation IN ('replacement', 'transfer') AND completed_at IS NOT NULL)
        """
      )
    )

    execute(
      "ALTER TABLE discord_identity_recovery_audit_events DROP CONSTRAINT discord_identity_recovery_audit_events_action_check"
    )

    create(
      constraint(
        :discord_identity_recovery_audit_events,
        :discord_identity_recovery_audit_events_action_check,
        check:
          "action IN ('opened_and_contained', 'discord_oauth_proved', 'destination_magic_link_proved', 'approved', 'completed')"
      )
    )

    create table(:discord_identity_recovery_proofs, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :recovery_case_id,
        references(:discord_identity_recovery_cases, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:kind, :text, null: false)
      add(:subject, :text)
      add(:subject_fingerprint, :text)
      add(:principal_id, references(:principals, type: :uuid, on_delete: :restrict))
      add(:proof_digest, :text, null: false)
      add(:expires_at, :timestamptz, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(
      unique_index(:discord_identity_recovery_proofs, [:recovery_case_id, :kind],
        name: :discord_identity_recovery_live_proof_unique
      )
    )

    create(
      constraint(:discord_identity_recovery_proofs, :discord_identity_recovery_proofs_kind_check,
        check: "kind IN ('discord_oauth', 'destination_magic_link')"
      )
    )

    create(
      constraint(
        :discord_identity_recovery_proofs,
        :discord_identity_recovery_proofs_payload_check,
        check: """
        (kind = 'discord_oauth' AND subject IS NOT NULL AND subject_fingerprint IS NOT NULL AND principal_id IS NULL)
        OR
        (kind = 'destination_magic_link' AND subject IS NULL AND subject_fingerprint IS NULL AND principal_id IS NOT NULL)
        """
      )
    )

    create table(:discord_identity_recovery_approvals, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :recovery_case_id,
        references(:discord_identity_recovery_cases, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:approver_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:approval_digest, :text, null: false)
      add(:source_binding_fingerprint, :text, null: false)

      add(:destination_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:incoming_subject_fingerprint, :text, null: false)
      add(:evidence_references, {:array, :text}, null: false)
      add(:operation, :text, null: false)
      add(:expires_at, :timestamptz, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(
      unique_index(
        :discord_identity_recovery_approvals,
        [:recovery_case_id, :approver_principal_id],
        name: :discord_identity_recovery_approval_approver_unique
      )
    )

    create(
      constraint(
        :discord_identity_recovery_approvals,
        :discord_identity_recovery_approvals_operation_check,
        check: "operation IN ('replacement', 'transfer')"
      )
    )

    create table(:discord_identity_binding_history, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :recovery_case_id,
        references(:discord_identity_recovery_cases, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :old_external_identity_id,
        references(:external_identities, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :new_external_identity_id,
        references(:external_identities, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:source_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:destination_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:operation, :text, null: false)
      add(:incoming_subject_fingerprint, :text, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(
      constraint(
        :discord_identity_binding_history,
        :discord_identity_binding_history_operation_check,
        check: "operation IN ('replacement', 'transfer')"
      )
    )

    create(
      unique_index(:discord_identity_binding_history, [:recovery_case_id],
        name: :discord_identity_binding_history_case_unique
      )
    )

    for table <- [
          :discord_identity_recovery_proofs,
          :discord_identity_recovery_approvals,
          :discord_identity_binding_history
        ] do
      execute(
        "CREATE FUNCTION ale221_reject_#{table}_mutation() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'identity recovery history is immutable' USING ERRCODE = '23514'; END; $$ LANGUAGE plpgsql;"
      )

      execute(
        "CREATE TRIGGER ale221_reject_#{table}_mutation BEFORE UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION ale221_reject_#{table}_mutation();"
      )
    end

    replace_ale217_binding_functions(true)
  end

  def down do
    replace_ale217_binding_functions(false)

    for table <- [
          :discord_identity_binding_history,
          :discord_identity_recovery_approvals,
          :discord_identity_recovery_proofs
        ] do
      execute("DROP TRIGGER IF EXISTS ale221_reject_#{table}_mutation ON #{table}")
      execute("DROP FUNCTION IF EXISTS ale221_reject_#{table}_mutation()")
      drop(table(table))
    end

    execute(
      "ALTER TABLE discord_identity_recovery_cases DROP CONSTRAINT discord_identity_recovery_cases_state_check"
    )

    create(
      constraint(:discord_identity_recovery_cases, :discord_identity_recovery_cases_state_check,
        check: "state = 'open'"
      )
    )

    execute(
      "ALTER TABLE discord_identity_recovery_audit_events DROP CONSTRAINT discord_identity_recovery_audit_events_action_check"
    )

    create(
      constraint(
        :discord_identity_recovery_audit_events,
        :discord_identity_recovery_audit_events_action_check,
        check: "action = 'opened_and_contained'"
      )
    )

    alter table(:discord_identity_recovery_cases) do
      remove(:completed_at)
      remove(:operation)
      remove(:incoming_subject_fingerprint)
      remove(:destination_principal_id)
    end

    drop_if_exists(
      unique_index(:external_identities, [:provider, :provider_subject],
        name: "unique_external_identities_provider_subject"
      )
    )

    drop_if_exists(
      unique_index(:external_identities, [:principal_id, :provider],
        name: "unique_external_identities_principal_provider"
      )
    )

    alter table(:external_identities), do: remove(:retired_at)

    create(
      unique_index(:external_identities, [:provider, :provider_subject],
        name: "unique_external_identities_provider_subject"
      )
    )

    create(
      unique_index(:external_identities, [:principal_id, :provider],
        name: "unique_external_identities_principal_provider"
      )
    )
  end

  defp replace_ale217_binding_functions(retired_column?) do
    active_identity = if retired_column?, do: " AND ei.retired_at IS NULL", else: ""

    current_active =
      if retired_column?, do: " OR current_identity.retired_at IS NOT NULL", else: ""

    execute("""
    CREATE OR REPLACE FUNCTION ale217_check_assignment_binding() RETURNS trigger AS $$
    DECLARE current_assignment staged_discord_assignments%ROWTYPE;
    BEGIN
      SELECT * INTO current_assignment FROM staged_discord_assignments WHERE id = NEW.id;
      IF NOT FOUND OR current_assignment.state NOT IN ('proposed', 'approved') THEN RETURN NULL; END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('discord/principal/' || current_assignment.principal_id::text, 0));
      PERFORM pg_advisory_xact_lock(hashtextextended('discord/subject/discord/' || current_assignment.provider_subject, 0));
      IF NOT EXISTS (
        SELECT 1 FROM user_profiles up
        JOIN member_profiles mp ON mp.user_profile_id = up.id AND mp.id = up.principal_id
        WHERE up.principal_id = current_assignment.principal_id
      ) THEN
        RAISE EXCEPTION 'assignment principal is not linked to a current member'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_member_link';
      END IF;
      IF EXISTS (
        SELECT 1 FROM external_identities ei
        WHERE ei.provider = 'discord'#{active_identity}
          AND (ei.principal_id = current_assignment.principal_id OR ei.provider_subject = current_assignment.provider_subject)
      ) THEN
        RAISE EXCEPTION 'assignment conflicts with permanent identity'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_external_identity_conflict';
      END IF;
      IF EXISTS (
        SELECT 1 FROM invitation_acceptance_discord_subject_claims c
        WHERE c.provider = 'discord' AND c.provider_subject = current_assignment.provider_subject
      ) THEN
        RAISE EXCEPTION 'assignment conflicts with active subject claim'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_subject_claim_conflict';
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ale217_check_external_identity_binding() RETURNS trigger AS $$
    DECLARE current_identity external_identities%ROWTYPE;
    BEGIN
      SELECT * INTO current_identity FROM external_identities WHERE id = NEW.id;
      IF NOT FOUND OR current_identity.provider <> 'discord'#{current_active} THEN RETURN NULL; END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('discord/principal/' || current_identity.principal_id::text, 0));
      PERFORM pg_advisory_xact_lock(hashtextextended('discord/subject/discord/' || current_identity.provider_subject, 0));
      IF EXISTS (
        SELECT 1 FROM staged_discord_assignments a
        WHERE a.state IN ('proposed', 'approved')
          AND (a.principal_id = current_identity.principal_id OR a.provider_subject = current_identity.provider_subject)
      ) THEN
        RAISE EXCEPTION 'permanent identity conflicts with active assignment'
          USING ERRCODE = '23514', CONSTRAINT = 'external_identities_active_assignment_conflict';
      END IF;
      IF EXISTS (
        SELECT 1 FROM invitation_acceptance_discord_subject_claims c
        WHERE c.provider = 'discord' AND c.provider_subject = current_identity.provider_subject
      ) THEN
        RAISE EXCEPTION 'permanent identity conflicts with active subject claim'
          USING ERRCODE = '23514', CONSTRAINT = 'external_identities_subject_claim_conflict';
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ale217_check_subject_claim_binding() RETURNS trigger AS $$
    DECLARE current_claim invitation_acceptance_discord_subject_claims%ROWTYPE;
    BEGIN
      SELECT * INTO current_claim FROM invitation_acceptance_discord_subject_claims WHERE id = NEW.id;
      IF NOT FOUND OR current_claim.provider <> 'discord' THEN RETURN NULL; END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('discord/subject/discord/' || current_claim.provider_subject, 0));
      IF EXISTS (
        SELECT 1 FROM staged_discord_assignments a
        WHERE a.state IN ('proposed', 'approved') AND a.provider = 'discord'
          AND a.provider_subject = current_claim.provider_subject
      ) THEN
        RAISE EXCEPTION 'subject claim conflicts with active assignment'
          USING ERRCODE = '23514', CONSTRAINT = 'discord_subject_claims_active_assignment_conflict';
      END IF;
      IF EXISTS (
        SELECT 1 FROM external_identities ei
        WHERE ei.provider = 'discord'#{active_identity}
          AND ei.provider_subject = current_claim.provider_subject
      ) THEN
        RAISE EXCEPTION 'subject claim conflicts with permanent identity'
          USING ERRCODE = '23514', CONSTRAINT = 'discord_subject_claims_external_identity_conflict';
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end
end
