defmodule Dhc.Repo.Migrations.Ale178InvitationIdentifierSplit do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:invitations, [:email, :status])
    drop_if_exists index(:invitations, [:email])

    execute "ALTER TABLE invitations DROP COLUMN search_text"

    rename table(:invitations), :user_id, to: :prospective_principal_id
    rename table(:invitations), :created_by, to: :created_by_principal_id
    rename table(:invitation_processing_logs), :user_id, to: :principal_id

    execute """
    ALTER TABLE invitations
      ALTER COLUMN email TYPE citext USING email::citext
    """

    execute """
    ALTER TABLE invitations
      ADD COLUMN search_text tsvector
        GENERATED ALWAYS AS (
          setweight(to_tsvector('english', coalesce(email::text, '')), 'B')
        ) STORED
    """

    create unique_index(:invitations, [:email],
             where: "status = 'pending'",
             name: :invitations_email_pending_unique
           )

    create unique_index(:invitations, [:prospective_principal_id])

    execute """
    ALTER TABLE invitations
      RENAME CONSTRAINT invitations_created_by_fkey
      TO invitations_created_by_principal_id_fkey
    """

    execute """
    ALTER TABLE invitation_processing_logs
      RENAME CONSTRAINT invitation_processing_logs_user_id_fkey
      TO invitation_processing_logs_principal_id_fkey
    """

    execute """
    ALTER INDEX invitation_processing_logs_user_id_index
      RENAME TO invitation_processing_logs_principal_id_index
    """
  end

  def down do
    raise "ALE-178 is unsafe to roll back after invitation reissues; restore from backup"
  end
end
