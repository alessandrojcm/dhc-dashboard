defmodule Dhc.Repo.Migrations.Ale214AddPaymentPendingAcceptanceStatus do
  use Ecto.Migration

  def up do
    execute("DROP INDEX invitation_acceptance_attempts_active_unique")

    drop constraint(
           :invitation_acceptance_attempts,
           :invitation_acceptance_attempts_status_check
         )

    create constraint(
             :invitation_acceptance_attempts,
             :invitation_acceptance_attempts_status_check,
             check:
               "status IN ('processing', 'payment_pending', 'cleanup_pending', 'provisioned', 'completed', 'declined')"
           )

    execute("""
    CREATE UNIQUE INDEX invitation_acceptance_attempts_active_unique
      ON invitation_acceptance_attempts (invitation_id)
      WHERE status IN ('processing', 'payment_pending', 'cleanup_pending', 'provisioned')
    """)
  end

  def down do
    execute("DROP INDEX invitation_acceptance_attempts_active_unique")

    execute("""
    UPDATE invitation_acceptance_attempts
    SET status = 'processing'
    WHERE status = 'payment_pending'
    """)

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

    execute("""
    CREATE UNIQUE INDEX invitation_acceptance_attempts_active_unique
      ON invitation_acceptance_attempts (invitation_id)
      WHERE status IN ('processing', 'cleanup_pending', 'provisioned')
    """)
  end
end
