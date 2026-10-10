defmodule Dhc.BeginnersWorkshops.Workers.ReconcileWorker do
  @moduledoc """
  ALE-382: periodically repairs missed Stripe events for Beginners' Workshop
  payments and refunds.

  A driver only (the `Dhc.Workshops.Workers.RefundReconciliationWorker`
  shape): the `:system` command `:reconcile` does the work in one bounded
  pass — it re-enqueues submission of pending refunds, applies Stripe's
  current status to processing ones, and settles live and releasing payment
  rows whose Checkout Session already completed or expired. What does not fit
  in one pass is left to the next tick.

  `unique` over incomplete states means a cron tick never starts a second
  pass while one is still running or waiting to retry.
  """

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  alias Dhc.BeginnersWorkshops

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case BeginnersWorkshops.execute(:system, :reconcile) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
