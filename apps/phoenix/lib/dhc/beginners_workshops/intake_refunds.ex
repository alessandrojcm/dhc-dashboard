defmodule Dhc.BeginnersWorkshops.IntakeRefunds do
  @moduledoc """
  The Stripe-facing half of Intake refunds (ALE-382). Internal to the
  boundary: only `Dhc.BeginnersWorkshops.Commands` calls it, and always
  **between transactions** — nothing here touches the database.

  A refund is always the full amount the payment row took, against its
  PaymentIntent, under the row's idempotency key
  `beginners-intake-refund:<id>`, so a retried submission replays the refund
  Stripe already created. Metadata names the refund row, which lets a
  `refund.*` event that arrives before the submission is recorded still find
  it; any other refund (a Workshop's) is not ours.
  """

  alias Dhc.BeginnersWorkshops.IntakeRefund
  alias Dhc.Stripe.{Failure, Operations}

  @metadata_type "beginners_intake_refund"

  @typedoc "`:retryable` (try again later) or `:rejected` (Stripe refused the request)."
  @type failure :: :retryable | :rejected

  @doc "Creates (or, for a retried key, replays) the Stripe refund of a refund row."
  @spec create(IntakeRefund.t(), String.t()) :: {:ok, map()} | {:error, failure(), term()}
  def create(%IntakeRefund{} = refund, payment_intent_id) when is_binary(payment_intent_id) do
    body = %{
      "payment_intent" => payment_intent_id,
      "amount" => refund.amount_cents,
      "reason" => "requested_by_customer",
      "metadata[type]" => @metadata_type,
      "metadata[refund_id]" => refund.id
    }

    case Operations.post_refunds(body, idempotency_key: refund.idempotency_key) do
      {:ok, %{"id" => id} = object} when is_binary(id) -> {:ok, object}
      {:ok, unexpected} -> {:error, :retryable, {:unexpected_response, unexpected}}
      {:error, reason} -> {:error, failure(reason), reason}
    end
  end

  @doc "Retrieves a Stripe refund."
  @spec retrieve(String.t()) :: {:ok, map()} | {:error, failure(), term()}
  def retrieve(stripe_refund_id) when is_binary(stripe_refund_id) do
    case Operations.get_refunds_refund(stripe_refund_id, %{}) do
      {:ok, %{"id" => _id} = object} -> {:ok, object}
      {:ok, unexpected} -> {:error, :retryable, {:unexpected_response, unexpected}}
      {:error, reason} -> {:error, failure(reason), reason}
    end
  end

  @doc "The refund row a Stripe refund object names, when it is one of ours."
  @spec refund_id(map()) :: String.t() | nil
  def refund_id(%{"metadata" => %{"type" => @metadata_type, "refund_id" => id}})
      when is_binary(id),
      do: id

  def refund_id(_object), do: nil

  @doc """
  A Stripe refund status as a refund row status: `succeeded` is
  `completed`, `failed` and `canceled` are `failed`, anything else
  (`pending`, `requires_action`) is still `processing`.
  """
  @spec local_status(String.t() | nil) :: String.t()
  def local_status("succeeded"), do: "completed"
  def local_status("failed"), do: "failed"
  def local_status("canceled"), do: "failed"
  def local_status(_pending), do: "processing"

  defp failure(reason), do: if(Failure.retryable?(reason), do: :retryable, else: :rejected)
end
