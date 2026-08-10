defmodule Dhc.Workshops.StripeAdapter.Live do
  @moduledoc false

  @behaviour Dhc.Workshops.StripeAdapter

  alias Dhc.Stripe.Operations

  @impl true
  def create_payment_intent(params) do
    form =
      [
        {:amount, params.amount},
        {:currency, params.currency},
        {"metadata[type]", "workshop_registration"},
        {"metadata[workshop_id]", params.workshop_id},
        {"metadata[workshop_title]", params.workshop_title},
        {"metadata[user_id]", params.user_id},
        {"metadata[actor_type]", "member"},
        {"automatic_payment_methods[enabled]", "false"},
        {"payment_method_types[]", "card"},
        {"payment_method_types[]", "link"}
      ]
      |> maybe_put_customer(params.customer_id)

    Operations.post_payment_intents(form,
      client: stripe_client(),
      idempotency_key: params.idempotency_key
    )
  end

  @impl true
  def retrieve_payment_intent(id) do
    Operations.get_payment_intents_intent(id, %{}, client: stripe_client())
  end

  @impl true
  def create_checkout_session(params) do
    Operations.post_checkout_sessions(params.body,
      client: stripe_client(),
      idempotency_key: params.idempotency_key
    )
  end

  @impl true
  def retrieve_checkout_session(id) do
    Operations.get_checkout_sessions_session(id, %{}, client: stripe_client())
  end

  @impl true
  def update_payment_intent(id, params) do
    case Operations.post_payment_intents_intent(id, params, client: stripe_client()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_refund(params) do
    Operations.post_refunds(params.body,
      client: stripe_client(),
      idempotency_key: params.idempotency_key
    )
  end

  @impl true
  def retrieve_refund(id) do
    Operations.get_refunds_refund(id, %{}, client: stripe_client())
  end

  defp maybe_put_customer(form, nil), do: form
  defp maybe_put_customer(form, ""), do: form
  defp maybe_put_customer(form, customer_id), do: [{:customer, customer_id} | form]

  defp stripe_client do
    Application.get_env(:dhc, :workshop_stripe_client, Dhc.Stripe.Client)
  end
end
