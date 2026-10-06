defmodule Dhc.Workshops.Workers.RefundWorker do
  @moduledoc """
  Submits one Workshop Refund to Stripe.

  A driver only (ALE-340): it turns its arguments into the
  `{:submit_refund, refund_id}` command of `Dhc.Workshops.PaymentCommands`,
  which re-reads the Refund under its locks, calls Stripe outside any
  transaction with the Refund's stable idempotency key, and records the
  result through the transition table.
  """

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Dhc.Workshops.PaymentCommands

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refund_id" => refund_id}}) when is_binary(refund_id) do
    case PaymentCommands.execute(:system, {:submit_refund, refund_id}) do
      {:ok, _outcome} -> :ok
      {:error, :refund_not_found} -> {:discard, :refund_not_found}
      {:error, {:intervention_required, reason}} -> {:discard, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}
end
