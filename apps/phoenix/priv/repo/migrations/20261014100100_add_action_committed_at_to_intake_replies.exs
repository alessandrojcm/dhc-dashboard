defmodule Dhc.Repo.Migrations.AddActionCommittedAtToIntakeReplies do
  use Ecto.Migration

  # ALE-412: when a Reply Action that writes no Intake history row (a
  # restore) committed, stamped inside the command's own transaction, so a
  # retried job knows it already ran. Deploy shape: additive.
  def change do
    alter table(:beginners_workshop_intake_replies) do
      add :action_committed_at, :utc_datetime_usec
    end
  end
end
