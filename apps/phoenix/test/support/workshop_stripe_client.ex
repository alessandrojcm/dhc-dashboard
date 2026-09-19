defmodule DhcWeb.WorkshopStripeClient do
  @moduledoc """
  Stripe request fake for workshop controller contract tests.
  """

  def request(%{method: :get, url: url}), do: request(method: :get, url: url)

  def request(%{method: method, url: url, body: body}),
    do: request(method: method, url: url, body: body)

  def request(method: :post, url: "/v1/checkout/sessions", body: body) do
    Application.put_env(:dhc, :last_workshop_checkout_request, body)

    Application.put_env(
      :dhc,
      :workshop_payment_attempt_id,
      form_value(body, :"metadata[payment_attempt_id]")
    )

    case Application.get_env(:dhc, :workshop_stripe_checkout_create_response, :ok) do
      :ok ->
        {:ok,
         %{
           "id" => "cs_test_external",
           "client_secret" => "cs_test_external_secret",
           "url" => nil
         }}

      other ->
        other
    end
  end

  def request(method: :get, url: "/v1/checkout/sessions/" <> checkout_session_id) do
    case Application.get_env(:dhc, :workshop_stripe_checkout_retrieve_response) do
      nil ->
        {:ok,
         %{
           "id" => checkout_session_id,
           "status" => "complete",
           "payment_status" => "paid",
           "amount_total" => 2500,
           "currency" => "eur",
           "payment_intent" => "pi_external",
           "metadata" => %{
             "type" => "workshop_registration",
             "actor_type" => "external",
             "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_workshop_id),
             "payment_attempt_id" => Application.fetch_env!(:dhc, :workshop_payment_attempt_id)
           },
           "customer_details" => %{
             "email" => " Guest@Example.com ",
             "name" => "Grace Hopper",
             "phone" => "+353123456"
           }
         }}

      other ->
        other
    end
  end

  def request(method: :post, url: "/v1/payment_intents", body: body) do
    Application.put_env(:dhc, :last_workshop_stripe_request, {:create_payment_intent, body})

    case Application.get_env(:dhc, :workshop_stripe_create_response, :ok) do
      :ok ->
        {:ok,
         %{
           "id" => "pi_test_member",
           "client_secret" => "pi_test_member_secret",
           "amount" => form_value(body, :amount),
           "currency" => form_value(body, :currency),
           "status" => "requires_payment_method",
           "metadata" => %{}
         }}

      other ->
        other
    end
  end

  def request(method: :get, url: "/v1/payment_intents/" <> payment_intent_id) do
    case Application.get_env(:dhc, :workshop_stripe_retrieve_response) do
      nil ->
        {:ok,
         %{
           "id" => payment_intent_id,
           "status" => "succeeded",
           "amount" => 1000,
           "currency" => "eur",
           "metadata" => %{
             "type" => "workshop_registration",
             "actor_type" => "member",
             "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_workshop_id),
             "user_id" => "11111111-1111-1111-1111-111111111111"
           }
         }}

      other ->
        other
    end
  end

  def request(method: :post, url: "/v1/refunds", body: body) do
    Application.put_env(:dhc, :last_workshop_stripe_refund_request, body)

    case Application.get_env(:dhc, :workshop_stripe_refund_response, :ok) do
      :ok -> {:ok, %{"id" => "re_test_member"}}
      other -> other
    end
  end

  def request(method: :post, url: "/v1/payment_intents/" <> _id, body: body) do
    Application.put_env(:dhc, :last_workshop_payment_intent_update, body)
    {:ok, %{"id" => "pi_external"}}
  end

  defp form_value(body, key) do
    body
    |> Enum.find_value(fn
      {^key, value} -> value
      _ -> nil
    end)
  end
end
