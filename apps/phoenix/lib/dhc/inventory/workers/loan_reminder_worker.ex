defmodule Dhc.Inventory.Workers.LoanReminderWorker do
  @moduledoc """
  ALE-287: the scheduled pass that delivers loan reminders and repairs missed
  ones.

  Normal delivery and reconciliation are the same call
  (`Dhc.Inventory.LoanReminders.run/0`), so this worker has no catch-up branch:
  a tick that never fired, a node that was down, and a job that crashed
  mid-delivery all leave the same evidence in the ledger, and the next run
  repairs it. That is what satisfies "scheduled reconciliation that repairs
  missed events" without a second mechanism able to disagree with the first.

  Runs hourly rather than daily so a missed window is repaired within the hour
  instead of the next day; a pass in an unchanged state delivers nothing, so
  the extra frequency costs one query. `unique` over incomplete states keeps
  overlapping ticks from piling up, and the ledger claim makes an overlap safe
  anyway.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  require Logger

  alias Dhc.Inventory

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Inventory.run_loan_reminders() do
      %{failed: 0} ->
        :ok

      # Undelivered claims stay in the ledger, so the next scheduled pass
      # retries them. The job itself succeeds: retrying the whole pass would
      # re-walk every healthy loan to chase one bad recipient, and the ledger
      # already guarantees the repair.
      %{delivered: delivered, failed: failed} ->
        Logger.warning(
          "[loan-reminder-worker] #{failed} reminder(s) could not be delivered and will be retried on the next pass",
          delivered: delivered,
          failed: failed
        )

        :ok
    end
  end
end
