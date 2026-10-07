defmodule Dhc.Workshops.Workers.RefundReconciliationWorker do
  @moduledoc """
  Periodically reconciles Workshop Refunds: re-enqueues submission for pending
  Refunds and applies Stripe's current status to processing ones.

  A driver only (ALE-340): the `:reconcile_refunds` command of
  `Dhc.Workshops.PaymentCommands` does the work, and bounds each pass to a
  fixed number of Refunds, least recently written first. A backlog larger
  than one pass is left to the next 15-minute tick rather than chained
  follow-up jobs: the per-Refund work is idempotent, nothing is lost by
  waiting, and one job at a time keeps overlap impossible.

  `unique` over incomplete states (including `executing` and `retryable`)
  means a cron tick never starts a second pass while one is still running or
  waiting to retry.
  """

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  alias Dhc.Workshops.PaymentCommands

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case PaymentCommands.execute(:system, :reconcile_refunds) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
