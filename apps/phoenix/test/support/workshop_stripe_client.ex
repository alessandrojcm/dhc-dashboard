defmodule DhcWeb.WorkshopStripeClient do
  @moduledoc """
  Stripe HTTP fake for workshop controller contract tests.

  A `Req.Test` plug over the one Stripe transport seam (ALE-342): the test
  installs it with `Req.Test.stub(Dhc.Stripe, DhcWeb.WorkshopStripeClient)`,
  so the live `Dhc.Workshops.StripeAdapter.Live` and `Dhc.Stripe.Client` run
  for real and only the HTTP hop is faked.

  Answers are driven by `Application` env so individual tests can swap them:
  a configured `{:ok, map}` is sent as JSON, `{:error, {:stripe_api, status,
  body}}` as that Stripe error, and any other `{:error, reason}` as a
  transport failure. The last request bodies are recorded as flat form maps
  (`"metadata[workshop_id]" => id`), exactly as Stripe receives them.
  """

  @behaviour Plug

  alias Dhc.StripeHTTPStub

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: route(conn.method, conn.request_path, conn)

  defp route("POST", "/v1/checkout/sessions", conn) do
    body = StripeHTTPStub.form(conn)
    Application.put_env(:dhc, :last_workshop_checkout_request, body)
    Application.put_env(:dhc, :workshop_payment_attempt_id, body["metadata[payment_attempt_id]"])

    respond(conn, Application.get_env(:dhc, :workshop_stripe_checkout_create_response, :ok), %{
      "id" => "cs_test_external",
      "client_secret" => "cs_test_external_secret",
      "url" => nil
    })
  end

  defp route("GET", "/v1/checkout/sessions/" <> checkout_session_id, conn) do
    respond(
      conn,
      Application.get_env(:dhc, :workshop_stripe_checkout_retrieve_response, :ok),
      fn ->
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
        }
      end
    )
  end

  defp route("POST", "/v1/payment_intents", conn) do
    body = StripeHTTPStub.form(conn)
    Application.put_env(:dhc, :last_workshop_stripe_request, {:create_payment_intent, body})

    respond(conn, Application.get_env(:dhc, :workshop_stripe_create_response, :ok), %{
      "id" => "pi_test_member",
      "client_secret" => "pi_test_member_secret",
      "amount" => String.to_integer(body["amount"]),
      "currency" => body["currency"],
      "status" => "requires_payment_method",
      "metadata" => %{}
    })
  end

  defp route("GET", "/v1/payment_intents/" <> payment_intent_id, conn) do
    respond(conn, Application.get_env(:dhc, :workshop_stripe_retrieve_response, :ok), fn ->
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
      }
    end)
  end

  defp route("POST", "/v1/refunds", conn) do
    Application.put_env(:dhc, :last_workshop_stripe_refund_request, StripeHTTPStub.form(conn))

    respond(conn, Application.get_env(:dhc, :workshop_stripe_refund_response, :ok), %{
      "id" => "re_test_member"
    })
  end

  defp route("POST", "/v1/payment_intents/" <> _id, conn) do
    Application.put_env(:dhc, :last_workshop_payment_intent_update, StripeHTTPStub.form(conn))
    StripeHTTPStub.json(conn, %{"id" => "pi_external"})
  end

  defp route(method, path, _conn), do: raise("unexpected Stripe request #{method} #{path}")

  defp respond(conn, :ok, default) when is_function(default, 0),
    do: StripeHTTPStub.json(conn, default.())

  defp respond(conn, :ok, default), do: StripeHTTPStub.json(conn, default)
  defp respond(conn, nil, default), do: respond(conn, :ok, default)
  defp respond(conn, {:ok, body}, _default), do: StripeHTTPStub.json(conn, body)

  defp respond(conn, {:error, {:stripe_api, status, body}}, _default),
    do: StripeHTTPStub.json(conn, status, body)

  defp respond(conn, {:error, reason}, _default) when is_atom(reason),
    do: StripeHTTPStub.transport_error(conn, reason)
end
