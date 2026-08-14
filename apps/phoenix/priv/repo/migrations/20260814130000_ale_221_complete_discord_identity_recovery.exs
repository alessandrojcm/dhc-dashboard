defmodule Dhc.Repo.Migrations.Ale221CompleteDiscordIdentityRecovery do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE principal_tokens DROP CONSTRAINT principal_tokens_context_check")

    execute("""
    ALTER TABLE principal_tokens
    ADD CONSTRAINT principal_tokens_context_check
    CHECK (
      context IN ('login', 'session', 'socket')
      OR context ~* '^identity_recovery:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    )
    """)

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
      add(:terminal_at, :timestamptz)
      add(:terminal_reason_code, :text)

      add(
        :terminal_actor_principal_id,
        references(:principals, type: :uuid, on_delete: :restrict)
      )
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

    create(
      constraint(
        :discord_identity_recovery_cases,
        :discord_identity_recovery_cases_terminal_check,
        check: """
        (state IN ('failed', 'cancelled', 'expired') AND terminal_at IS NOT NULL AND terminal_reason_code IS NOT NULL AND terminal_actor_principal_id IS NOT NULL)
        OR
        (state IN ('open', 'completed') AND terminal_at IS NULL AND terminal_reason_code IS NULL AND terminal_actor_principal_id IS NULL)
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
          "action IN ('opened_and_contained', 'discord_oauth_proved', 'discord_oauth_refreshed', 'destination_magic_link_proved', 'destination_magic_link_refreshed', 'approved', 'completed', 'failed', 'cancelled', 'expired')"
      )
    )

    drop_if_exists(
      unique_index(:discord_identity_recovery_audit_events, [:recovery_case_id, :action])
    )

    create(index(:discord_identity_recovery_audit_events, [:recovery_case_id, :action]))

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
      add(:attempt, :integer, null: false)
      add(:expires_at, :timestamptz, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(
      unique_index(:discord_identity_recovery_proofs, [:recovery_case_id, :kind, :attempt],
        name: :discord_identity_recovery_proof_attempt_unique
      )
    )

    create(
      constraint(
        :discord_identity_recovery_proofs,
        :discord_identity_recovery_proofs_attempt_check,
        check: "attempt > 0"
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

      add(
        :discord_oauth_proof_id,
        references(:discord_identity_recovery_proofs, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :destination_magic_link_proof_id,
        references(:discord_identity_recovery_proofs, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:approval_digest, :text, null: false)
      add(:attempt, :integer, null: false)
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
        [:recovery_case_id, :approver_principal_id, :attempt],
        name: :discord_identity_recovery_approval_attempt_unique
      )
    )

    create(
      constraint(
        :discord_identity_recovery_approvals,
        :discord_identity_recovery_approvals_attempt_check,
        check: "attempt > 0"
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

    execute("""
    CREATE OR REPLACE FUNCTION ale220_reject_recovery_case_mutation() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE'
         AND OLD.state = 'open'
         AND NEW.state = 'completed'
         AND OLD.id IS NOT DISTINCT FROM NEW.id
         AND OLD.external_identity_id IS NOT DISTINCT FROM NEW.external_identity_id
         AND OLD.case_reference IS NOT DISTINCT FROM NEW.case_reference
         AND OLD.reason_code IS NOT DISTINCT FROM NEW.reason_code
         AND OLD.reporter_reference IS NOT DISTINCT FROM NEW.reporter_reference
         AND OLD.binding_fingerprint IS NOT DISTINCT FROM NEW.binding_fingerprint
         AND OLD.evidence_references IS NOT DISTINCT FROM NEW.evidence_references
         AND OLD.actor_principal_id IS NOT DISTINCT FROM NEW.actor_principal_id
         AND OLD.opened_at IS NOT DISTINCT FROM NEW.opened_at
         AND OLD.created_at IS NOT DISTINCT FROM NEW.created_at
         AND OLD.destination_principal_id IS NULL
         AND OLD.incoming_subject_fingerprint IS NULL
         AND OLD.operation IS NULL
         AND OLD.completed_at IS NULL
         AND OLD.terminal_at IS NULL
         AND OLD.terminal_reason_code IS NULL
         AND OLD.terminal_actor_principal_id IS NULL
         AND NEW.destination_principal_id IS NOT NULL
         AND NEW.incoming_subject_fingerprint IS NOT NULL
         AND NEW.operation IN ('replacement', 'transfer')
         AND NEW.completed_at IS NOT NULL
         AND NEW.terminal_at IS NULL
         AND NEW.terminal_reason_code IS NULL
         AND NEW.terminal_actor_principal_id IS NULL THEN
        RETURN NEW;
      END IF;

      IF TG_OP = 'UPDATE'
         AND OLD.state = 'open'
         AND NEW.state IN ('failed', 'cancelled', 'expired')
         AND OLD.id IS NOT DISTINCT FROM NEW.id
         AND OLD.external_identity_id IS NOT DISTINCT FROM NEW.external_identity_id
         AND OLD.case_reference IS NOT DISTINCT FROM NEW.case_reference
         AND OLD.reason_code IS NOT DISTINCT FROM NEW.reason_code
         AND OLD.reporter_reference IS NOT DISTINCT FROM NEW.reporter_reference
         AND OLD.binding_fingerprint IS NOT DISTINCT FROM NEW.binding_fingerprint
         AND OLD.evidence_references IS NOT DISTINCT FROM NEW.evidence_references
         AND OLD.actor_principal_id IS NOT DISTINCT FROM NEW.actor_principal_id
         AND OLD.opened_at IS NOT DISTINCT FROM NEW.opened_at
         AND OLD.created_at IS NOT DISTINCT FROM NEW.created_at
         AND OLD.destination_principal_id IS NULL
         AND OLD.incoming_subject_fingerprint IS NULL
         AND OLD.operation IS NULL
         AND OLD.completed_at IS NULL
         AND OLD.terminal_at IS NULL
         AND OLD.terminal_reason_code IS NULL
         AND OLD.terminal_actor_principal_id IS NULL
         AND NEW.destination_principal_id IS NULL
         AND NEW.incoming_subject_fingerprint IS NULL
         AND NEW.operation IS NULL
         AND NEW.completed_at IS NULL
         AND NEW.terminal_at IS NOT NULL
         AND NEW.terminal_reason_code IS NOT NULL
         AND NEW.terminal_actor_principal_id IS NOT NULL THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'identity recovery cases are immutable except for valid completion'
        USING ERRCODE = '23514', CONSTRAINT = 'discord_identity_recovery_cases_immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE FUNCTION ale221_append_recovery_proof_audit() RETURNS trigger AS $$
    BEGIN
      INSERT INTO discord_identity_recovery_audit_events
        (id, recovery_case_id, action, actor_principal_id, created_at)
      SELECT gen_random_uuid(), NEW.recovery_case_id,
        CASE
          WHEN NEW.kind = 'discord_oauth' AND NEW.attempt = 1 THEN 'discord_oauth_proved'
          WHEN NEW.kind = 'discord_oauth' THEN 'discord_oauth_refreshed'
          WHEN NEW.kind = 'destination_magic_link' AND NEW.attempt = 1 THEN 'destination_magic_link_proved'
          WHEN NEW.kind = 'destination_magic_link' THEN 'destination_magic_link_refreshed'
        END,
        recovery_case.actor_principal_id,
        NEW.created_at
      FROM discord_identity_recovery_cases recovery_case
      WHERE recovery_case.id = NEW.recovery_case_id;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ale221_append_recovery_proof_audit
      AFTER INSERT ON discord_identity_recovery_proofs
      FOR EACH ROW EXECUTE FUNCTION ale221_append_recovery_proof_audit();
    """)

    execute("""
    CREATE FUNCTION ale221_append_recovery_approval_audit() RETURNS trigger AS $$
    BEGIN
      INSERT INTO discord_identity_recovery_audit_events
        (id, recovery_case_id, action, actor_principal_id, created_at)
      VALUES
        (gen_random_uuid(), NEW.recovery_case_id, 'approved', NEW.approver_principal_id, NEW.created_at);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ale221_append_recovery_approval_audit
      AFTER INSERT ON discord_identity_recovery_approvals
      FOR EACH ROW EXECUTE FUNCTION ale221_append_recovery_approval_audit();
    """)

    execute("""
    CREATE FUNCTION ale221_append_recovery_completion_audit() RETURNS trigger AS $$
    DECLARE completion_actor uuid;
    BEGIN
      IF OLD.state = 'open' AND NEW.state = 'completed' THEN
        SELECT approver_principal_id INTO completion_actor
        FROM discord_identity_recovery_approvals
        WHERE recovery_case_id = NEW.id
        ORDER BY created_at, id
        LIMIT 1;

        INSERT INTO discord_identity_recovery_audit_events
          (id, recovery_case_id, action, actor_principal_id, created_at)
        VALUES
          (gen_random_uuid(), NEW.id, 'completed', completion_actor, NEW.completed_at);
      ELSIF OLD.state = 'open' AND NEW.state IN ('failed', 'cancelled', 'expired') THEN
        INSERT INTO discord_identity_recovery_audit_events
          (id, recovery_case_id, action, actor_principal_id, created_at)
        VALUES
          (gen_random_uuid(), NEW.id, NEW.state, NEW.terminal_actor_principal_id, NEW.terminal_at);
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER ale221_append_recovery_completion_audit
      AFTER UPDATE ON discord_identity_recovery_cases
      FOR EACH ROW EXECUTE FUNCTION ale221_append_recovery_completion_audit();
    """)

    replace_ale217_binding_functions(true)
  end

  def down do
    raise """
    ALE-221 is intentionally irreversible after identity recovery is enabled.
    Completed recoveries retain duplicate historical subjects/owners and immutable
    proof, approval, audit, and binding history. Roll forward with a compatible
    subject-only release or pause Discord sign-in; never down-migrate this data.
    """
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
