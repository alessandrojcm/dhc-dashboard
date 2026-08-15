defmodule Dhc.Repo.Migrations.EnforceDiscordClaimInvariants do
  use Ecto.Migration

  def up do
    create table(:invitation_acceptance_discord_collision_audit_events, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :continuation_id,
          references(:invitation_acceptance_discord_continuations,
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :existing_principal_id, :uuid
      add :subject_fingerprint, :text, null: false
      add :reason_code, :text, null: false
      add :created_at, :timestamptz, null: false, default: fragment("NOW()")
    end

    create unique_index(
             :invitation_acceptance_discord_collision_audit_events,
             [:continuation_id],
             name: :iac_discord_collision_audit_continuation_unique
           )

    create constraint(
             :invitation_acceptance_discord_collision_audit_events,
             :iac_discord_collision_audit_reason_check,
             check:
               "reason_code IN ('external_identity', 'staged_assignment', 'active_claim') AND ((reason_code IN ('external_identity', 'staged_assignment') AND existing_principal_id IS NOT NULL) OR (reason_code = 'active_claim' AND existing_principal_id IS NULL))"
           )

    execute """
    CREATE FUNCTION dhc_discord_lock_principal(principal uuid) RETURNS void AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('discord/principal/' || principal::text, 0));
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE FUNCTION dhc_discord_lock_subject(provider text, subject text) RETURNS void AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(hashtextextended('discord/subject/' || provider || '/' || subject, 0));
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE FUNCTION verify_iac_discord_continuation_attempt() RETURNS trigger AS $$
    DECLARE
      current_continuation invitation_acceptance_discord_continuations%ROWTYPE;
      attempt_invitation_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'invitation_acceptance_attempts' THEN
        FOR current_continuation IN
          SELECT * FROM invitation_acceptance_discord_continuations WHERE attempt_id = NEW.id
        LOOP
          IF current_continuation.invitation_id IS DISTINCT FROM NEW.invitation_id THEN
            RAISE EXCEPTION 'Discord continuation invitation does not match its attempt'
              USING ERRCODE = 'check_violation', CONSTRAINT = 'iac_discord_continuation_attempt_mismatch';
          END IF;
        END LOOP;
      ELSE
        SELECT invitation_id INTO attempt_invitation_id
          FROM invitation_acceptance_attempts
         WHERE id = NEW.attempt_id;

        IF attempt_invitation_id IS NULL OR attempt_invitation_id IS DISTINCT FROM NEW.invitation_id THEN
          RAISE EXCEPTION 'Discord continuation invitation does not match its attempt'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'iac_discord_continuation_attempt_mismatch';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE FUNCTION verify_iac_discord_claim() RETURNS trigger AS $$
    DECLARE
      current_claim invitation_acceptance_discord_subject_claims%ROWTYPE;
      current_continuation invitation_acceptance_discord_continuations%ROWTYPE;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        SELECT * INTO current_continuation
          FROM invitation_acceptance_discord_continuations
         WHERE id = OLD.continuation_id;

        IF current_continuation.status = 'verified' THEN
          RAISE EXCEPTION 'Verified Discord continuation must retain its subject claim'
            USING ERRCODE = 'check_violation', CONSTRAINT = 'iac_discord_verified_claim_required';
        END IF;

        RETURN OLD;
      END IF;

      SELECT * INTO current_claim
        FROM invitation_acceptance_discord_subject_claims
       WHERE id = NEW.id;

      IF NOT FOUND THEN
        RETURN NEW;
      END IF;

      PERFORM dhc_discord_lock_subject(current_claim.provider, current_claim.provider_subject);

      SELECT * INTO current_continuation
        FROM invitation_acceptance_discord_continuations
       WHERE id = current_claim.continuation_id;

      IF current_continuation.status IS DISTINCT FROM 'verified'
         OR current_continuation.provider_subject IS DISTINCT FROM current_claim.provider_subject
         OR current_claim.provider IS DISTINCT FROM 'discord'
         OR current_continuation.expires_at <= transaction_timestamp() THEN
        RAISE EXCEPTION 'Discord subject claim must belong to a live matching verified continuation'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'iac_discord_claim_owner_invalid';
      END IF;

      IF EXISTS (
        SELECT 1 FROM external_identities identity
       WHERE identity.provider = current_claim.provider
         AND identity.provider_subject = current_claim.provider_subject
         AND identity.retired_at IS NULL
      ) THEN
        RAISE EXCEPTION 'Discord subject cannot be both claimed and permanently linked'
          USING ERRCODE = 'unique_violation', CONSTRAINT = 'iac_discord_claim_external_identity_conflict';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE FUNCTION verify_iac_discord_continuation_claim() RETURNS trigger AS $$
    DECLARE
      current_continuation invitation_acceptance_discord_continuations%ROWTYPE;
      matching_claims bigint;
    BEGIN
      SELECT * INTO current_continuation
        FROM invitation_acceptance_discord_continuations
       WHERE id = NEW.id;

      IF NOT FOUND THEN
        RETURN NEW;
      END IF;

      SELECT count(*) INTO matching_claims
        FROM invitation_acceptance_discord_subject_claims claim
       WHERE claim.continuation_id = current_continuation.id
         AND claim.provider = 'discord'
         AND claim.provider_subject = current_continuation.provider_subject;

      IF current_continuation.status = 'verified' AND matching_claims <> 1 THEN
        RAISE EXCEPTION 'Verified Discord continuation must own exactly one matching claim'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'iac_discord_verified_claim_required';
      END IF;

      IF current_continuation.status <> 'verified' AND matching_claims <> 0 THEN
        RAISE EXCEPTION 'Terminal Discord continuation cannot retain a claim'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'iac_discord_terminal_claim_forbidden';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE FUNCTION verify_external_identity_discord_claim() RETURNS trigger AS $$
    BEGIN
      IF NEW.provider <> 'discord' OR NEW.retired_at IS NOT NULL THEN
        RETURN NEW;
      END IF;

      PERFORM dhc_discord_lock_principal(NEW.principal_id);
      PERFORM dhc_discord_lock_subject(NEW.provider, NEW.provider_subject);

      IF EXISTS (
        SELECT 1 FROM invitation_acceptance_discord_subject_claims claim
         WHERE claim.provider = NEW.provider
           AND claim.provider_subject = NEW.provider_subject
      ) THEN
        RAISE EXCEPTION 'Discord subject cannot be both claimed and permanently linked'
          USING ERRCODE = 'unique_violation', CONSTRAINT = 'iac_discord_claim_external_identity_conflict';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE FUNCTION reject_iac_discord_collision_audit_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'Discord collision audit events are immutable'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'iac_discord_collision_audit_immutable';
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE CONSTRAINT TRIGGER iac_discord_continuation_attempt_check
      AFTER INSERT OR UPDATE OF invitation_id, attempt_id
      ON invitation_acceptance_discord_continuations
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION verify_iac_discord_continuation_attempt()
    """

    execute """
    CREATE CONSTRAINT TRIGGER iac_discord_attempt_continuation_check
      AFTER UPDATE OF invitation_id ON invitation_acceptance_attempts
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION verify_iac_discord_continuation_attempt()
    """

    execute """
    CREATE CONSTRAINT TRIGGER iac_discord_claim_owner_check
      AFTER INSERT OR UPDATE OF continuation_id, provider, provider_subject
      ON invitation_acceptance_discord_subject_claims
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION verify_iac_discord_claim()
    """

    execute """
    CREATE CONSTRAINT TRIGGER iac_discord_claim_delete_check
      AFTER DELETE ON invitation_acceptance_discord_subject_claims
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION verify_iac_discord_claim()
    """

    execute """
    CREATE CONSTRAINT TRIGGER iac_discord_continuation_claim_check
      AFTER INSERT OR UPDATE OF status, provider_subject, expires_at
      ON invitation_acceptance_discord_continuations
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION verify_iac_discord_continuation_claim()
    """

    execute """
    CREATE CONSTRAINT TRIGGER external_identity_discord_claim_check
      AFTER INSERT OR UPDATE OF provider, provider_subject, principal_id
      ON external_identities
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION verify_external_identity_discord_claim()
    """

    execute """
    CREATE TRIGGER iac_discord_collision_audit_immutable
      BEFORE UPDATE OR DELETE ON invitation_acceptance_discord_collision_audit_events
      FOR EACH ROW EXECUTE FUNCTION reject_iac_discord_collision_audit_mutation()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS iac_discord_collision_audit_immutable ON invitation_acceptance_discord_collision_audit_events"
    execute "DROP TRIGGER IF EXISTS external_identity_discord_claim_check ON external_identities"

    execute "DROP TRIGGER IF EXISTS iac_discord_continuation_claim_check ON invitation_acceptance_discord_continuations"

    execute "DROP TRIGGER IF EXISTS iac_discord_claim_delete_check ON invitation_acceptance_discord_subject_claims"

    execute "DROP TRIGGER IF EXISTS iac_discord_claim_owner_check ON invitation_acceptance_discord_subject_claims"

    execute "DROP TRIGGER IF EXISTS iac_discord_attempt_continuation_check ON invitation_acceptance_attempts"

    execute "DROP TRIGGER IF EXISTS iac_discord_continuation_attempt_check ON invitation_acceptance_discord_continuations"

    execute "DROP FUNCTION IF EXISTS reject_iac_discord_collision_audit_mutation()"
    execute "DROP FUNCTION IF EXISTS verify_external_identity_discord_claim()"
    execute "DROP FUNCTION IF EXISTS verify_iac_discord_continuation_claim()"
    execute "DROP FUNCTION IF EXISTS verify_iac_discord_claim()"
    execute "DROP FUNCTION IF EXISTS verify_iac_discord_continuation_attempt()"
    execute "DROP FUNCTION IF EXISTS dhc_discord_lock_subject(text, text)"
    execute "DROP FUNCTION IF EXISTS dhc_discord_lock_principal(uuid)"

    drop table(:invitation_acceptance_discord_collision_audit_events)
  end
end
