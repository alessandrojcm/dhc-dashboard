defmodule Dhc.Workshops.Workers.RefundReconciliationWorker do
  @moduledoc """
  Periodically reconciles Workshop Refunds: re-enqueues submission for pending
  Refunds and applies Stripe's current status to processing ones.

  A driver only (ALE-340): the `:reconcile_refunds` command of
  `Dhc.Workshops.PaymentCommands` does the work.
  """

  use Oban.Worker, queue: :stripe, max_attempts: 5, unique: [period: 300]

  alias Dhc.Workshops.PaymentCommands

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case PaymentCommands.execute(:system, :reconcile_refunds) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
