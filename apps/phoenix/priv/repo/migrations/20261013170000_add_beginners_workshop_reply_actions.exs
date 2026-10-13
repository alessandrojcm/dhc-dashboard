defmodule Dhc.Repo.Migrations.AddBeginnersWorkshopReplyActions do
  use Ecto.Migration

  # ALE-411: what an Intake Reply was classified as and which Reply Action
  # (if any) it ran, and the Intake history row that names a reply as its
  # actor. No body, subject or address is stored.
  def change do
    alter table(:beginners_workshop_intake_replies) do
      add :intent, :text
      add :intent_probabilities, :map
      add :intent_confidence, :float
      add :money_back, :float
      add :model, :text
      # The Reply Action chosen (`decline`, `defer`, …), written before it
      # runs so a retried job never classifies again.
      add :command, :text
      add :decided_at, :utc_datetime_usec
    end

    alter table(:beginners_workshop_intake_events) do
      # The Intake Reply whose Reply Action this row records. Deliberately no
      # foreign key: the reply row is deleted with the person, while the
      # anonymised Intake keeps its history, which must still read "by email
      # reply". The id links to nothing else.
      add :intake_reply_id, :binary_id
    end

    create index(:beginners_workshop_intake_events, [:intake_reply_id],
             where: "intake_reply_id IS NOT NULL"
           )
  end
end
