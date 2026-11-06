defmodule Dhc.Repo.Migrations.BackfillBeginnersWorkshopEndTimes do
  use Ecto.Migration

  def up do
    # ALE-431: the club approved six civil hours as the legacy baseline.
    # Do not replace explicitly recorded times or wrap into an overnight
    # session. No cutoff, contact schedule or attendance rule changes here.
    execute """
    UPDATE beginners_workshops
    SET end_time = start_time + interval '6 hours'
    WHERE end_time IS NULL AND start_time < time '18:00'
    """
  end

  # A later coordinator correction cannot be distinguished from this baseline.
  # Preserve data on release rollback; the original column migration owns DDL.
  def down, do: :ok
end
