defmodule Dhc.Workshops.Workers.RefundWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args]]

  import Ecto.Query

  alias Dhc.Repo
  alias Dhc.Workshops.{PaymentAttempt, Refund, Registration}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refund_id" => refund_id}}) do
    case Repo.get(Refund, refund_id) do
      nil ->
        {:discard, :refund_not_found}

      %Refund{status: status} when status in ["completed", "failed", "cancelled"] ->
        :ok

      %Refund{status: "processing", stripe_refund_id: id} when is_binary(id) ->
        :ok

      %Refund{} = refund ->
        submit(refund)
    end
  end

  def perform(_job), do: {:discard, :invalid_args}

  defp submit(refund) do
    with {:ok, payment_intent_id} <- resolve_payment_intent(refund),
         {:ok, response} <-
           stripe_adapter().create_refund(%{
             body: [
               payment_intent: payment_intent_id,
               amount: refund.refund_amount,
               reason: "requested_by_customer"
             ],
             idempotency_key: refund.idempotency_key
           }) do
      mark_provider_accepted(refund, payment_intent_id, response)
    else
      {:error, {:stripe_api, status, _body} = reason}
      when status in 400..499 and status not in [408, 409, 429] ->
        mark_intervention_required(refund, reason)

      {:error, :payment_intent_not_resolvable = reason} ->
        mark_intervention_required(refund, reason)

      {:error, reason} ->
        record_retryable_error(refund, reason)
        {:error, reason}
    end
  end

  defp resolve_payment_intent(%Refund{stripe_payment_intent_id: id})
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp resolve_payment_intent(%Refund{registration_id: registration_id})
       when is_binary(registration_id) do
    registration = Repo.get(Registration, registration_id)

    case registration do
      %Registration{stripe_payment_intent_id: id} when is_binary(id) and id != "" ->
        {:ok, id}

      %Registration{stripe_checkout_session_id: id} when is_binary(id) and id != "" ->
        case stripe_adapter().retrieve_checkout_session(id) do
          {:ok, %{"payment_intent" => payment_intent_id}}
          when is_binary(payment_intent_id) and payment_intent_id != "" ->
            {:ok, payment_intent_id}

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :payment_intent_not_resolvable}
        end

      _ ->
        {:error, :payment_intent_not_resolvable}
    end
  end

  defp resolve_payment_intent(%Refund{payment_attempt_id: payment_attempt_id})
       when is_binary(payment_attempt_id) do
    case Repo.get(PaymentAttempt, payment_attempt_id) do
      %PaymentAttempt{stripe_payment_intent_id: id} when is_binary(id) and id != "" ->
        {:ok, id}

      %PaymentAttempt{stripe_checkout_session_id: id} when is_binary(id) and id != "" ->
        resolve_checkout_payment_intent(id)

      _ ->
        {:error, :payment_intent_not_resolvable}
    end
  end

  defp resolve_payment_intent(_refund), do: {:error, :payment_intent_not_resolvable}

  defp resolve_checkout_payment_intent(checkout_session_id) do
    case stripe_adapter().retrieve_checkout_session(checkout_session_id) do
      {:ok, %{"payment_intent" => payment_intent_id}}
      when is_binary(payment_intent_id) and payment_intent_id != "" ->
        {:ok, payment_intent_id}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :payment_intent_not_resolvable}
    end
  end

  defp mark_provider_accepted(refund, payment_intent_id, response) do
    provider_status = Map.get(response, "status", "pending")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      status: if(provider_status == "succeeded", do: "completed", else: "processing"),
      stripe_refund_id: Map.fetch!(response, "id"),
      stripe_payment_intent_id: payment_intent_id,
      provider_status: provider_status,
      processed_at: refund.processed_at || now,
      completed_at: if(provider_status == "succeeded", do: now, else: nil),
      last_error: nil
    }

    Repo.transaction(fn ->
      refund
      |> Ecto.Changeset.change(attrs)
      |> Repo.update!()

      if provider_status == "succeeded" and is_binary(refund.payment_attempt_id) do
        from(pa in PaymentAttempt, where: pa.id == ^refund.payment_attempt_id)
        |> Repo.update_all(set: [status: "refunded", concluded_at: now, updated_at: now])
      end
    end)

    :ok
  end

  defp mark_intervention_required(refund, reason) do
    refund
    |> Ecto.Changeset.change(status: "failed", last_error: error_text(reason))
    |> Repo.update!()

    {:discard, reason}
  end

  defp record_retryable_error(refund, reason) do
    from(r in Refund, where: r.id == ^refund.id)
    |> Repo.update_all(set: [last_error: error_text(reason), updated_at: DateTime.utc_now()])
  end

  defp error_text(reason), do: reason |> inspect() |> String.slice(0, 2_000)

  defp stripe_adapter do
    Application.fetch_env!(:dhc, :workshop_stripe_adapter)
  end
end
