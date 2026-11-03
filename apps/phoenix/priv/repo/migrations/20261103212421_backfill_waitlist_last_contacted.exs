defmodule Dhc.Repo.Migrations.BackfillWaitlistLastContacted do
  use Ecto.Migration

  def up do
    execute """
    UPDATE waitlist AS person
    SET last_contacted = history.queued_at
    FROM (
      SELECT intake.waitlist_id,
             date_trunc('second', max(email.queued_at)) AT TIME ZONE 'UTC' AS queued_at
      FROM beginners_workshop_intake_emails AS email
      JOIN beginners_workshop_intakes AS intake ON intake.id = email.intake_id
      WHERE intake.waitlist_id IS NOT NULL
      GROUP BY intake.waitlist_id
    ) AS history
    WHERE person.id = history.waitlist_id
      AND (person.last_contacted IS NULL OR person.last_contacted < history.queued_at)
    """
  end

  # A data correction: rolling back code must not erase contact history.
  def down, do: :ok
end
