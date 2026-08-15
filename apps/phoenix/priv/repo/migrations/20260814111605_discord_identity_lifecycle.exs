defmodule Dhc.Repo.Migrations.DiscordIdentityLifecycle do
  use Ecto.Migration

  def up do
    alter table(:external_identities) do
      add(:sign_in_disabled_at, :timestamptz)
      add(:retired_at, :timestamptz)
    end

    replace_identity_unique_indexes("retired_at IS NULL")
    replace_ale217_binding_functions(true)
  end

  def down do
    replace_ale217_binding_functions(false)
    replace_identity_unique_indexes(nil)

    alter table(:external_identities) do
      remove(:retired_at)
      remove(:sign_in_disabled_at)
    end
  end

  defp replace_identity_unique_indexes(predicate) do
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
        where: predicate,
        name: "unique_external_identities_provider_subject"
      )
    )

    create(
      unique_index(:external_identities, [:principal_id, :provider],
        where: predicate,
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
