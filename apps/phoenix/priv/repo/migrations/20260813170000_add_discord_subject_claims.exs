defmodule Dhc.Repo.Migrations.AddDiscordSubjectClaims do
  use Ecto.Migration

  def change do
    alter table(:invitation_acceptance_discord_continuations) do
      add :provider_subject, :text
      add :subject_fingerprint, :text
      add :display_metadata, :map, null: false, default: fragment("'{}'::jsonb")
    end

    create constraint(
             :invitation_acceptance_discord_continuations,
             :iac_discord_continuations_raw_subject_check,
             check:
               "(status = 'verified' AND NULLIF(provider_subject, '') IS NOT NULL) OR (status <> 'verified' AND provider_subject IS NULL)"
           )

    create constraint(
             :invitation_acceptance_discord_continuations,
             :iac_discord_continuations_terminal_display_check,
             check: "status = 'verified' OR display_metadata = '{}'::jsonb"
           )

    create constraint(
             :invitation_acceptance_discord_continuations,
             :iac_discord_continuations_fingerprint_check,
             check:
               "(status IN ('verified', 'consumed', 'collision') AND NULLIF(subject_fingerprint, '') IS NOT NULL) OR (status IN ('awaiting_oauth', 'failed') AND subject_fingerprint IS NULL) OR status IN ('expired', 'cancelled')"
           )

    create constraint(
             :invitation_acceptance_discord_continuations,
             :iac_discord_continuations_conclusion_check,
             check:
               "(status IN ('awaiting_oauth', 'verified') AND concluded_at IS NULL) OR (status IN ('consumed', 'expired', 'cancelled', 'collision', 'failed') AND concluded_at IS NOT NULL)"
           )

    create table(:invitation_acceptance_discord_subject_claims, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :continuation_id,
          references(:invitation_acceptance_discord_continuations,
            type: :uuid,
            on_delete: :restrict
          ),
          null: false

      add :provider, :text, null: false
      add :provider_subject, :text, null: false

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create unique_index(:invitation_acceptance_discord_subject_claims, [:continuation_id],
             name: :iac_discord_claims_continuation_unique
           )

    create unique_index(
             :invitation_acceptance_discord_subject_claims,
             [:provider, :provider_subject],
             name: :iac_discord_claims_provider_subject_unique
           )

    create constraint(
             :invitation_acceptance_discord_subject_claims,
             :iac_discord_claims_provider_subject_check,
             check: "provider = 'discord' AND NULLIF(provider_subject, '') IS NOT NULL"
           )
  end
end
