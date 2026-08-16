defmodule Dhc.Repo.Migrations.HardenAcceptanceRecovery do
  use Ecto.Migration

  def up do
    alter table(:invitation_acceptance_attempts) do
      add :operation_token, :uuid
      add :operation_started_at, :timestamptz
    end

    create constraint(
             :invitation_acceptance_attempts,
             :invitation_acceptance_attempts_operation_lease_check,
             check: "(operation_token IS NULL) = (operation_started_at IS NULL)"
           )

    drop constraint(
           :invitation_acceptance_discord_continuations,
           :iac_discord_continuations_fingerprint_check
         )

    # Legacy failed Continuations were zeroized before their subject fingerprint
    # was retained, so the stricter replacement cannot be validated retroactively.
    # NOT VALID still enforces the constraint for every new or updated row.
    execute("""
    ALTER TABLE invitation_acceptance_discord_continuations
    ADD CONSTRAINT iac_discord_continuations_fingerprint_check
    CHECK (
      (status IN ('verified', 'consumed', 'collision') AND NULLIF(subject_fingerprint, '') IS NOT NULL)
      OR (status = 'awaiting_oauth' AND subject_fingerprint IS NULL)
      OR (status = 'failed' AND (subject_fingerprint IS NULL OR NULLIF(subject_fingerprint, '') IS NOT NULL))
      OR status IN ('expired', 'cancelled')
    ) NOT VALID
    """)
  end

  def down do
    execute("""
    UPDATE invitation_acceptance_discord_continuations
    SET subject_fingerprint = NULL
    WHERE status = 'failed'
    """)

    drop constraint(
           :invitation_acceptance_discord_continuations,
           :iac_discord_continuations_fingerprint_check
         )

    create constraint(
             :invitation_acceptance_discord_continuations,
             :iac_discord_continuations_fingerprint_check,
             check:
               "(status IN ('verified', 'consumed', 'collision') AND NULLIF(subject_fingerprint, '') IS NOT NULL) OR (status IN ('awaiting_oauth', 'failed') AND subject_fingerprint IS NULL) OR status IN ('expired', 'cancelled')"
           )

    drop constraint(
           :invitation_acceptance_attempts,
           :invitation_acceptance_attempts_operation_lease_check
         )

    alter table(:invitation_acceptance_attempts) do
      remove :operation_started_at
      remove :operation_token
    end
  end
end
