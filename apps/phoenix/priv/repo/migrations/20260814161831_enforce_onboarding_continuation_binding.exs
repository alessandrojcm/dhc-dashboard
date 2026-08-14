defmodule Dhc.Repo.Migrations.EnforceOnboardingContinuationBinding do
  use Ecto.Migration

  def change do
    create unique_index(
             :invitation_acceptance_attempts,
             [:id, :invitation_id],
             name: :invitation_acceptance_attempts_id_invitation_id_unique
           )

    execute(
      """
      ALTER TABLE invitation_acceptance_discord_continuations
        ADD CONSTRAINT invitation_acceptance_discord_continuations_attempt_invitation_fkey
        FOREIGN KEY (attempt_id, invitation_id)
        REFERENCES invitation_acceptance_attempts (id, invitation_id)
        ON DELETE RESTRICT
      """,
      """
      ALTER TABLE invitation_acceptance_discord_continuations
        DROP CONSTRAINT invitation_acceptance_discord_continuations_attempt_invitation_fkey
      """
    )
  end
end
