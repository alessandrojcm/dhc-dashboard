defmodule Dhc.BeginnersWorkshops.Workers.RefundWorker do
  @moduledoc """
  ALE-382: submits one Intake refund to Stripe.

  A driver only (the `Dhc.Workshops.Workers.RefundWorker` shape): it turns
  its arguments into the `:system` command `{:submit_refund, refund_id}`,
  which re-reads the refund under its locks, calls Stripe between
  transactions under the refund's idempotency key and records the answer
  through the transition table. A Stripe outage is an error, so Oban retries
  it; a refund Stripe refuses is recorded `failed` by the command (and the
  coordinators alerted), which is a successful job.
  """

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Dhc.BeginnersWorkshops

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refund_id" => refund_id}}) when is_binary(refund_id) do
    case BeginnersWorkshops.execute(:system, {:submit_refund, refund_id}) do
      {:ok, _outcome} -> :ok
      {:error, :refund_not_found} -> {:discard, :refund_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}
end
