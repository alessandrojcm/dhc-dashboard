defmodule Dhc.Repo.Migrations.StageReviewDiscordAssignments do
  use Ecto.Migration

  def up do
    create table(:discord_assignment_stage_executions, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:capture_id, :uuid, null: false)

      add(:preparer_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:tool_revision, :text, null: false)
      add(:executed_at, :timestamptz, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create table(:discord_assignment_review_executions, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:capture_id, :uuid, null: false)

      add(:reviewer_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:tool_revision, :text, null: false)
      add(:executed_at, :timestamptz, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create table(:staged_discord_assignments, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:principal_id, :uuid, null: false)

      add(:capture_id, :uuid, null: false)

      add(
        :stage_execution_id,
        references(:discord_assignment_stage_executions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:provider, :text, null: false, default: "discord")
      add(:provider_subject, :text, null: false)
      add(:username_snapshot, :text, null: false)
      add(:subject_fingerprint, :text, null: false)
      add(:state, :text, null: false, default: "proposed")

      add(:prepared_by_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:approved_by_principal_id, references(:principals, type: :uuid, on_delete: :restrict))

      add(
        :review_execution_id,
        references(:discord_assignment_review_executions, type: :uuid, on_delete: :restrict)
      )

      add(:approved_at, :timestamptz)
      add(:terminal_at, :timestamptz)

      add(
        :terminal_actor_principal_id,
        references(:principals, type: :uuid, on_delete: :restrict)
      )

      add(:reason_code, :text)
      add(:superseded_by_id, :uuid)
      add(:tool_revision, :text, null: false)
      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    execute("""
    ALTER TABLE staged_discord_assignments
      ADD CONSTRAINT staged_discord_assignments_superseded_by_fkey
      FOREIGN KEY (superseded_by_id) REFERENCES staged_discord_assignments(id)
      ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED
    """)

    create(
      unique_index(:staged_discord_assignments, [:principal_id],
        where: "state IN ('proposed', 'approved')",
        name: :staged_discord_assignments_active_principal
      )
    )

    create(
      unique_index(:staged_discord_assignments, [:provider, :provider_subject],
        where: "state IN ('proposed', 'approved')",
        name: :staged_discord_assignments_active_subject
      )
    )

    create(index(:staged_discord_assignments, [:capture_id]))
    create(index(:staged_discord_assignments, [:stage_execution_id]))
    create(index(:staged_discord_assignments, [:review_execution_id]))

    create(
      constraint(:staged_discord_assignments, :staged_discord_assignments_provider_check,
        check: "provider = 'discord' AND NULLIF(provider_subject, '') IS NOT NULL"
      )
    )

    create(
      constraint(:staged_discord_assignments, :staged_discord_assignments_snapshot_check,
        check:
          "NULLIF(username_snapshot, '') IS NOT NULL AND NULLIF(subject_fingerprint, '') IS NOT NULL"
      )
    )

    create(
      constraint(:staged_discord_assignments, :staged_discord_assignments_state_check,
        check:
          "state IN ('proposed', 'approved', 'rejected', 'withdrawn', 'superseded', 'promoted')"
      )
    )

    create(
      constraint(:staged_discord_assignments, :staged_discord_assignments_lifecycle_check,
        check: """
        (state = 'proposed' AND approved_by_principal_id IS NULL AND review_execution_id IS NULL
          AND approved_at IS NULL AND terminal_at IS NULL AND terminal_actor_principal_id IS NULL
          AND reason_code IS NULL AND superseded_by_id IS NULL)
        OR
        (state = 'approved' AND approved_by_principal_id IS NOT NULL
          AND approved_by_principal_id <> prepared_by_principal_id
          AND review_execution_id IS NOT NULL AND approved_at IS NOT NULL
          AND terminal_at IS NULL AND terminal_actor_principal_id IS NULL
          AND reason_code IS NULL AND superseded_by_id IS NULL)
        OR
        (state = 'rejected' AND approved_by_principal_id IS NULL AND review_execution_id IS NOT NULL
          AND approved_at IS NULL AND terminal_at IS NOT NULL
          AND terminal_actor_principal_id IS NOT NULL AND reason_code IS NOT NULL
          AND superseded_by_id IS NULL)
        OR
        (state = 'withdrawn'
          AND ((approved_by_principal_id IS NULL AND review_execution_id IS NULL AND approved_at IS NULL)
            OR (approved_by_principal_id IS NOT NULL AND approved_by_principal_id <> prepared_by_principal_id
              AND review_execution_id IS NOT NULL AND approved_at IS NOT NULL))
          AND terminal_at IS NOT NULL
          AND terminal_actor_principal_id IS NOT NULL AND reason_code IS NOT NULL
          AND superseded_by_id IS NULL)
        OR
        (state = 'superseded'
          AND ((approved_by_principal_id IS NULL AND review_execution_id IS NULL AND approved_at IS NULL)
            OR (approved_by_principal_id IS NOT NULL AND approved_by_principal_id <> prepared_by_principal_id
              AND review_execution_id IS NOT NULL AND approved_at IS NOT NULL))
          AND terminal_at IS NOT NULL
          AND terminal_actor_principal_id IS NOT NULL AND reason_code IS NOT NULL
          AND superseded_by_id IS NOT NULL)
        OR
        (state = 'promoted' AND approved_by_principal_id IS NOT NULL
          AND approved_by_principal_id <> prepared_by_principal_id
          AND review_execution_id IS NOT NULL AND approved_at IS NOT NULL
          AND terminal_at IS NOT NULL AND terminal_actor_principal_id IS NOT NULL
          AND reason_code IS NOT NULL AND superseded_by_id IS NULL)
        """
      )
    )

    create table(:discord_assignment_stage_results, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :stage_execution_id,
        references(:discord_assignment_stage_executions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:principal_id, references(:principals, type: :uuid, on_delete: :restrict), null: false)
      add(:subject_fingerprint, :text, null: false)
      add(:outcome, :text, null: false)

      add(
        :assignment_id,
        references(:staged_discord_assignments, type: :uuid, on_delete: :restrict)
      )

      add(:reason_code, :text)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(unique_index(:discord_assignment_stage_results, [:stage_execution_id, :principal_id]))

    create(
      constraint(
        :discord_assignment_stage_results,
        :discord_assignment_stage_results_outcome_check,
        check:
          "(outcome = 'proposed' AND assignment_id IS NOT NULL AND reason_code IS NULL) OR (outcome = 'conflicted' AND assignment_id IS NULL AND reason_code IS NOT NULL)"
      )
    )

    create table(:staged_discord_assignment_audit_events, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :assignment_id,
        references(:staged_discord_assignments, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:action, :text, null: false)
      add(:old_state, :text)
      add(:new_state, :text, null: false)

      add(:actor_principal_id, references(:principals, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:capture_id, :uuid, null: false)

      add(
        :stage_execution_id,
        references(:discord_assignment_stage_executions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :review_execution_id,
        references(:discord_assignment_review_executions, type: :uuid, on_delete: :restrict)
      )

      add(:reason_code, :text)
      add(:tool_revision, :text, null: false)
      add(:subject_fingerprint, :text, null: false)
      timestamps(type: :timestamptz, updated_at: false, inserted_at: :created_at)
    end

    create(index(:staged_discord_assignment_audit_events, [:assignment_id, :created_at]))

    create_mutation_and_audit_triggers()
    create_append_only_execution_triggers()
    create_execution_consistency_trigger()
    create_result_consistency_triggers()
    create_role_authorization_lock_trigger()
    create_binding_constraint_triggers()
  end

  def down do
    execute("DROP TRIGGER IF EXISTS discord_assignment_lock_admin_role_mutation ON user_roles")
    execute("DROP FUNCTION IF EXISTS discord_assignment_lock_admin_role_mutation()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_check_review_execution_dependents ON discord_assignment_review_executions"
    )

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_check_stage_result_consistency ON discord_assignment_stage_results"
    )

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_check_stage_execution_dependents ON discord_assignment_stage_executions"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_check_review_execution_dependents()")
    execute("DROP FUNCTION IF EXISTS discord_assignment_check_stage_result_consistency()")
    execute("DROP FUNCTION IF EXISTS discord_assignment_check_stage_execution_dependents()")

    for table <- [
          "discord_assignment_stage_executions",
          "discord_assignment_review_executions",
          "discord_assignment_stage_results"
        ] do
      execute("DROP TRIGGER IF EXISTS discord_assignment_reject_execution_mutation ON #{table}")
    end

    execute("DROP FUNCTION IF EXISTS discord_assignment_reject_execution_mutation()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_check_subject_claim_binding ON invitation_acceptance_discord_subject_claims"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_check_subject_claim_binding()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_check_external_identity_binding ON external_identities"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_check_external_identity_binding()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_check_binding ON staged_discord_assignments"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_check_binding()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_check_execution_consistency ON staged_discord_assignments"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_check_execution_consistency()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_reject_audit_mutation ON staged_discord_assignment_audit_events"
    )

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_reject_direct_audit_insert ON staged_discord_assignment_audit_events"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_reject_audit_mutation()")
    execute("DROP FUNCTION IF EXISTS discord_assignment_reject_direct_audit_insert()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_append_audit ON staged_discord_assignments"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_append_audit()")

    execute(
      "DROP TRIGGER IF EXISTS discord_assignment_guard_mutation ON staged_discord_assignments"
    )

    execute("DROP FUNCTION IF EXISTS discord_assignment_guard_mutation()")
    drop(table(:staged_discord_assignment_audit_events))
    drop(table(:discord_assignment_stage_results))
    drop(table(:staged_discord_assignments))
    drop(table(:discord_assignment_review_executions))
    drop(table(:discord_assignment_stage_executions))
  end

  defp create_mutation_and_audit_triggers do
    execute("""
    CREATE FUNCTION discord_assignment_guard_mutation() RETURNS trigger AS $$
    BEGIN
      IF (NEW.principal_id, NEW.capture_id, NEW.stage_execution_id, NEW.provider,
          NEW.provider_subject, NEW.username_snapshot, NEW.subject_fingerprint,
          NEW.prepared_by_principal_id, NEW.tool_revision)
         IS DISTINCT FROM
         (OLD.principal_id, OLD.capture_id, OLD.stage_execution_id, OLD.provider,
          OLD.provider_subject, OLD.username_snapshot, OLD.subject_fingerprint,
          OLD.prepared_by_principal_id, OLD.tool_revision) THEN
        RAISE EXCEPTION 'assignment identity evidence is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_identity_immutable';
      END IF;

      IF NEW.state IS NOT DISTINCT FROM OLD.state AND
         (NEW.approved_by_principal_id, NEW.review_execution_id, NEW.approved_at,
          NEW.terminal_at, NEW.terminal_actor_principal_id, NEW.reason_code,
          NEW.superseded_by_id)
         IS DISTINCT FROM
         (OLD.approved_by_principal_id, OLD.review_execution_id, OLD.approved_at,
          OLD.terminal_at, OLD.terminal_actor_principal_id, OLD.reason_code,
          OLD.superseded_by_id) THEN
        RAISE EXCEPTION 'assignment lifecycle evidence is immutable without a state transition'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_lifecycle_immutable';
      END IF;

      IF OLD.state = 'approved' AND
         (NEW.approved_by_principal_id, NEW.review_execution_id, NEW.approved_at)
         IS DISTINCT FROM
         (OLD.approved_by_principal_id, OLD.review_execution_id, OLD.approved_at) THEN
        RAISE EXCEPTION 'approved review evidence is immutable'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_review_evidence_immutable';
      END IF;

      IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
        (OLD.state = 'proposed' AND NEW.state IN ('approved', 'rejected', 'withdrawn', 'superseded')) OR
        (OLD.state = 'approved' AND NEW.state IN ('withdrawn', 'superseded', 'promoted'))
      ) THEN
        RAISE EXCEPTION 'invalid assignment state transition'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_transition_check';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER discord_assignment_guard_mutation
      BEFORE UPDATE ON staged_discord_assignments
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_guard_mutation();
    """)

    execute("""
    CREATE FUNCTION discord_assignment_append_audit() RETURNS trigger AS $$
    DECLARE
      audit_actor uuid;
    BEGIN
      IF TG_OP = 'UPDATE' AND NEW.state = OLD.state THEN RETURN NEW; END IF;
      audit_actor := CASE
        WHEN NEW.state = 'proposed' THEN NEW.prepared_by_principal_id
        WHEN NEW.state = 'approved' THEN NEW.approved_by_principal_id
        ELSE NEW.terminal_actor_principal_id
      END;

      INSERT INTO staged_discord_assignment_audit_events
        (id, assignment_id, action, old_state, new_state, actor_principal_id,
         capture_id, stage_execution_id, review_execution_id, reason_code, tool_revision,
         subject_fingerprint, created_at)
      VALUES
        (gen_random_uuid(), NEW.id, CASE WHEN TG_OP = 'INSERT' THEN 'proposed' ELSE NEW.state END,
         CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.state END, NEW.state, audit_actor,
         NEW.capture_id, NEW.stage_execution_id, NEW.review_execution_id, NEW.reason_code, NEW.tool_revision,
         NEW.subject_fingerprint, now());
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public;
    """)

    execute("""
    CREATE TRIGGER discord_assignment_append_audit
      AFTER INSERT OR UPDATE ON staged_discord_assignments
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_append_audit();
    """)

    execute("""
    CREATE FUNCTION discord_assignment_reject_direct_audit_insert() RETURNS trigger AS $$
    BEGIN
      IF pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'assignment audit events may only be inserted by the assignment trigger'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignment_audit_events_trigger_owned';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER discord_assignment_reject_direct_audit_insert
      BEFORE INSERT ON staged_discord_assignment_audit_events
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_reject_direct_audit_insert();
    """)

    execute("""
    CREATE FUNCTION discord_assignment_reject_audit_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'assignment audit events are immutable'
        USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignment_audit_events_immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER discord_assignment_reject_audit_mutation
      BEFORE UPDATE OR DELETE ON staged_discord_assignment_audit_events
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_reject_audit_mutation();
    """)
  end

  defp create_append_only_execution_triggers do
    execute("""
    CREATE FUNCTION discord_assignment_reject_execution_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'assignment execution evidence is append-only'
        USING ERRCODE = '23514', CONSTRAINT = TG_TABLE_NAME || '_immutable';
    END;
    $$ LANGUAGE plpgsql;
    """)

    for table <- [
          "discord_assignment_stage_executions",
          "discord_assignment_review_executions",
          "discord_assignment_stage_results"
        ] do
      execute("""
      CREATE TRIGGER discord_assignment_reject_execution_mutation
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION discord_assignment_reject_execution_mutation();
      """)
    end
  end

  defp create_result_consistency_triggers do
    execute("""
    CREATE FUNCTION discord_assignment_check_stage_result_consistency() RETURNS trigger AS $$
    DECLARE
      current_result discord_assignment_stage_results%ROWTYPE;
      assignment staged_discord_assignments%ROWTYPE;
    BEGIN
      SELECT * INTO current_result FROM discord_assignment_stage_results WHERE id = NEW.id;
      IF NOT FOUND THEN RETURN NULL; END IF;

      IF current_result.outcome = 'proposed' THEN
        SELECT * INTO assignment
        FROM staged_discord_assignments
        WHERE id = current_result.assignment_id;

        IF NOT FOUND OR assignment.stage_execution_id <> current_result.stage_execution_id
           OR assignment.principal_id <> current_result.principal_id
           OR assignment.subject_fingerprint <> current_result.subject_fingerprint THEN
          RAISE EXCEPTION 'stage result does not match its assignment'
            USING ERRCODE = '23514', CONSTRAINT = 'discord_assignment_stage_results_assignment_consistency';
        END IF;
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER discord_assignment_check_stage_result_consistency
      AFTER INSERT OR UPDATE ON discord_assignment_stage_results
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_check_stage_result_consistency();
    """)

    execute("""
    CREATE FUNCTION discord_assignment_check_stage_execution_dependents() RETURNS trigger AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM staged_discord_assignments assignment
        WHERE assignment.stage_execution_id = NEW.id
          AND (assignment.capture_id <> NEW.capture_id
            OR assignment.prepared_by_principal_id <> NEW.preparer_principal_id)
      ) OR EXISTS (
        SELECT 1
        FROM discord_assignment_stage_results result
        LEFT JOIN staged_discord_assignments assignment ON assignment.id = result.assignment_id
        WHERE result.stage_execution_id = NEW.id
          AND result.outcome = 'proposed'
          AND (assignment.id IS NULL OR assignment.stage_execution_id <> NEW.id)
      ) THEN
        RAISE EXCEPTION 'stage execution does not match its dependent evidence'
          USING ERRCODE = '23514', CONSTRAINT = 'discord_assignment_stage_executions_dependents_consistency';
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER discord_assignment_check_stage_execution_dependents
      AFTER INSERT OR UPDATE ON discord_assignment_stage_executions
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_check_stage_execution_dependents();
    """)

    execute("""
    CREATE FUNCTION discord_assignment_check_review_execution_dependents() RETURNS trigger AS $$
    DECLARE current_execution discord_assignment_review_executions%ROWTYPE;
    BEGIN
      SELECT * INTO current_execution
      FROM discord_assignment_review_executions
      WHERE id = NEW.id;
      IF NOT FOUND THEN RETURN NULL; END IF;

      IF NOT EXISTS (
        SELECT 1 FROM staged_discord_assignment_audit_events event
        WHERE event.review_execution_id = current_execution.id
      ) THEN
        RAISE EXCEPTION 'review execution has no immutable row results'
          USING ERRCODE = '23514', CONSTRAINT = 'discord_assignment_review_executions_applied_results';
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER discord_assignment_check_review_execution_dependents
      AFTER INSERT OR UPDATE ON discord_assignment_review_executions
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_check_review_execution_dependents();
    """)
  end

  defp create_role_authorization_lock_trigger do
    execute("""
    CREATE FUNCTION discord_assignment_lock_admin_role_mutation() RETURNS trigger AS $$
    BEGIN
      IF OLD.role IN ('admin', 'president', 'treasurer', 'committee_coordinator',
        'sparring_coordinator', 'workshop_coordinator', 'beginners_coordinator',
        'quartermaster', 'pr_manager', 'volunteer_coordinator',
        'research_coordinator', 'coach') THEN
        PERFORM pg_advisory_xact_lock(
          hashtextextended('discord/principal/' || OLD.principal_id::text, 0)
        );
      END IF;
      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER discord_assignment_lock_admin_role_mutation
      BEFORE UPDATE OR DELETE ON user_roles
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_lock_admin_role_mutation();
    """)
  end

  defp create_execution_consistency_trigger do
    execute("""
    CREATE FUNCTION discord_assignment_check_execution_consistency() RETURNS trigger AS $$
    DECLARE
      current_assignment staged_discord_assignments%ROWTYPE;
      stage_execution discord_assignment_stage_executions%ROWTYPE;
      review_execution discord_assignment_review_executions%ROWTYPE;
      expected_reviewer uuid;
    BEGIN
      SELECT * INTO current_assignment FROM staged_discord_assignments WHERE id = NEW.id;
      IF NOT FOUND THEN RETURN NULL; END IF;

      SELECT * INTO stage_execution
      FROM discord_assignment_stage_executions
      WHERE id = current_assignment.stage_execution_id;

      IF NOT FOUND OR stage_execution.capture_id <> current_assignment.capture_id
         OR stage_execution.preparer_principal_id <> current_assignment.prepared_by_principal_id THEN
        RAISE EXCEPTION 'assignment does not match its stage execution'
          USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_stage_execution_consistency';
      END IF;

      IF current_assignment.review_execution_id IS NOT NULL THEN
        SELECT * INTO review_execution
        FROM discord_assignment_review_executions
        WHERE id = current_assignment.review_execution_id;

        expected_reviewer := COALESCE(
          current_assignment.approved_by_principal_id,
          current_assignment.terminal_actor_principal_id
        );

         IF NOT FOUND OR review_execution.capture_id <> current_assignment.capture_id
           OR review_execution.reviewer_principal_id <> expected_reviewer
           OR review_execution.reviewer_principal_id = current_assignment.prepared_by_principal_id THEN
          RAISE EXCEPTION 'assignment does not match an independent review execution'
            USING ERRCODE = '23514', CONSTRAINT = 'staged_discord_assignments_review_execution_consistency';
        END IF;
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER discord_assignment_check_execution_consistency
      AFTER INSERT OR UPDATE ON staged_discord_assignments
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_check_execution_consistency();
    """)
  end

  defp create_binding_constraint_triggers do
    execute("""
    CREATE FUNCTION discord_assignment_check_binding() RETURNS trigger AS $$
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
        WHERE ei.provider = 'discord' AND (ei.principal_id = current_assignment.principal_id OR ei.provider_subject = current_assignment.provider_subject)
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
    CREATE CONSTRAINT TRIGGER discord_assignment_check_binding
      AFTER INSERT OR UPDATE ON staged_discord_assignments
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_check_binding();
    """)

    execute("""
    CREATE FUNCTION discord_assignment_check_external_identity_binding() RETURNS trigger AS $$
    DECLARE current_identity external_identities%ROWTYPE;
    BEGIN
      SELECT * INTO current_identity FROM external_identities WHERE id = NEW.id;
      IF NOT FOUND OR current_identity.provider <> 'discord' THEN RETURN NULL; END IF;

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
    CREATE CONSTRAINT TRIGGER discord_assignment_check_external_identity_binding
      AFTER INSERT OR UPDATE ON external_identities
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_check_external_identity_binding();
    """)

    execute("""
    CREATE FUNCTION discord_assignment_check_subject_claim_binding() RETURNS trigger AS $$
    DECLARE current_claim invitation_acceptance_discord_subject_claims%ROWTYPE;
    BEGIN
      SELECT * INTO current_claim
      FROM invitation_acceptance_discord_subject_claims
      WHERE id = NEW.id;

      IF NOT FOUND OR current_claim.provider <> 'discord' THEN RETURN NULL; END IF;

      PERFORM pg_advisory_xact_lock(hashtextextended('discord/subject/discord/' || current_claim.provider_subject, 0));

      IF EXISTS (
        SELECT 1 FROM staged_discord_assignments a
        WHERE a.state IN ('proposed', 'approved')
          AND a.provider = 'discord'
          AND a.provider_subject = current_claim.provider_subject
      ) THEN
        RAISE EXCEPTION 'subject claim conflicts with active assignment'
          USING ERRCODE = '23514', CONSTRAINT = 'discord_subject_claims_active_assignment_conflict';
      END IF;

      IF EXISTS (
        SELECT 1 FROM external_identities ei
        WHERE ei.provider = 'discord'
          AND ei.provider_subject = current_claim.provider_subject
      ) THEN
        RAISE EXCEPTION 'subject claim conflicts with permanent identity'
          USING ERRCODE = '23514', CONSTRAINT = 'discord_subject_claims_external_identity_conflict';
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER discord_assignment_check_subject_claim_binding
      AFTER INSERT OR UPDATE ON invitation_acceptance_discord_subject_claims
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION discord_assignment_check_subject_claim_binding();
    """)
  end
end
