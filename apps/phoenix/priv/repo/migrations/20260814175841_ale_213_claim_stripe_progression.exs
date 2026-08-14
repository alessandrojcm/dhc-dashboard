defmodule Dhc.Repo.Migrations.Ale213ClaimStripeProgression do
  use Ecto.Migration

  def up do
    drop constraint(
           :invitation_acceptance_attempts,
           :invitation_acceptance_attempts_status_check
         )

    create constraint(
             :invitation_acceptance_attempts,
             :invitation_acceptance_attempts_status_check,
             check:
               "status IN ('processing', 'stripe_progressing', 'cleanup_pending', 'provisioned', 'completed', 'declined')"
           )

    execute "DROP INDEX invitation_acceptance_attempts_active_unique"

    execute """
    CREATE UNIQUE INDEX invitation_acceptance_attempts_active_unique
      ON invitation_acceptance_attempts (invitation_id)
      WHERE status IN ('processing', 'stripe_progressing', 'cleanup_pending', 'provisioned')
    """
  end

  def down do
    execute "DROP INDEX invitation_acceptance_attempts_active_unique"

    execute """
    CREATE UNIQUE INDEX invitation_acceptance_attempts_active_unique
      ON invitation_acceptance_attempts (invitation_id)
      WHERE status IN ('processing', 'cleanup_pending', 'provisioned')
    """

    drop constraint(
           :invitation_acceptance_attempts,
           :invitation_acceptance_attempts_status_check
         )

    create constraint(
             :invitation_acceptance_attempts,
             :invitation_acceptance_attempts_status_check,
             check:
               "status IN ('processing', 'cleanup_pending', 'provisioned', 'completed', 'declined')"
           )
  end
end
