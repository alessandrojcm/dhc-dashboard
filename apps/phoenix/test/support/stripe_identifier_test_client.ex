defmodule Dhc.Workshops.StripeIdentifierTestClient do
  @moduledoc """
  Test-only Stripe client for `Dhc.Workshops.StripeIdentifierWriteTest`,
  driven by `Application` env so individual tests can swap responses without
  redefining the module. Mirrors the `DhcWeb.WorkshopStripeClient` shape,
  handling both the keyword-list `client.request(method: ..., url: ...,
  body: ...)` calls used by `Dhc.Workshops` and the map
  `client.request(%{...})` calls used by the generated
  `Dhc.Stripe.Operations.*` functions.
  """

  def request(%{method: :get, url: url}), do: request(method: :get, url: url)

  def request(%{method: method, url: url, body: body} = request) do
    Application.put_env(
      :dhc,
      :workshop_stripe_test_last_request_opts,
      Map.get(request, :opts, [])
    )

    request(method: method, url: url, body: body)
  end

  def request(method: :post, url: "/v1/payment_intents", body: _body) do
    {:ok,
     %{
       "id" => "pi_test_member",
       "client_secret" => "pi_test_member_secret",
       "amount" => 1000,
       "currency" => "eur",
       "status" => "requires_payment_method",
       "metadata" => %{}
     }}
  end

  def request(method: :get, url: "/v1/payment_intents/" <> payment_intent_id) do
    case Application.get_env(:dhc, :workshop_stripe_test_payment_intent_response) do
      nil ->
        {:ok, pi_retrieve_default(payment_intent_id)}

      other ->
        other
    end
  end

  def request(method: :get, url: "/v1/checkout/sessions/" <> checkout_session_id) do
    case Application.get_env(:dhc, :workshop_stripe_test_checkout_session_response) do
      nil ->
        {:ok, cs_retrieve_default(checkout_session_id)}

      other ->
        other
    end
  end

  def request(method: :post, url: "/v1/refunds", body: body) do
    Application.put_env(:dhc, :workshop_stripe_test_last_refund_request, body)

    case Application.get_env(:dhc, :workshop_stripe_test_refund_response, :ok) do
      :ok -> {:ok, %{"id" => "re_test_member"}}
      other -> other
    end
  end

  def request(_method, _url, _body), do: {:ok, %{}}
  def request(_), do: {:ok, %{}}

  defp pi_retrieve_default(payment_intent_id) do
    %{
      "id" => payment_intent_id,
      "status" => "succeeded",
      "amount" => 1000,
      "currency" => "eur",
      "metadata" => %{
        "type" => "workshop_registration",
        "actor_type" => "member",
        "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_workshop_id),
        "user_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_member_user_id)
      }
    }
  end

  defp cs_retrieve_default(checkout_session_id) do
    %{
      "id" => checkout_session_id,
      "status" => "complete",
      "payment_status" => "paid",
      "amount_total" => 2000,
      "currency" => "eur",
      "payment_intent" => "pi_from_checkout",
      "metadata" => %{
        "type" => "workshop_registration",
        "actor_type" => "external",
        "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_workshop_id),
        "payment_attempt_id" =>
          Application.fetch_env!(:dhc, :workshop_stripe_test_payment_attempt_id)
      },
      "customer_details" => %{
        "email" => "guest@example.com",
        "name" => "Grace Hopper",
        "phone" => "+353123456"
      }
    }
  end
end
