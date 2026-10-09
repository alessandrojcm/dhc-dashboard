defmodule Dhc.BeginnersIntakeStripe do
  @moduledoc """
  Stripe Checkout stubs for Beginners' Workshop Intake payment tests
  (ALE-381), over the one Stripe transport seam (`Dhc.StripeHTTPStub`).

  A created session takes its id from the idempotency key
  (`beginners-intake-payment:<row id>` → `cs_<row id>`), so a replayed
  create answers with the same session, as Stripe does. Routes follow
  `Req.Test` ownership: Tasks started by the test see them.
  """

  alias Dhc.BeginnersWorkshops.IntakePayment
  alias Dhc.StripeHTTPStub

  @doc "The session id a payment row's create answers with."
  def session_id(%IntakePayment{id: id}), do: session_id(id)
  def session_id(payment_id) when is_binary(payment_id), do: "cs_" <> payment_id

  @doc "The hosted Checkout URL of a session id."
  def checkout_url(session_id), do: "https://checkout.stripe.com/c/pay/#{session_id}"

  @doc """
  Answers `POST /v1/checkout/sessions` with a session derived from the
  idempotency key and sends `{:checkout_created, form, idempotency_key}` to
  `notify` (the test process by default).
  """
  def stub_create(notify \\ self()) do
    StripeHTTPStub.stub("POST", "/v1/checkout/sessions", fn conn ->
      key = StripeHTTPStub.header(conn, "idempotency-key")
      send(notify, {:checkout_created, StripeHTTPStub.form(conn), key})
      id = "cs_" <> (key |> String.split(":") |> List.last())

      StripeHTTPStub.json(conn, %{
        "id" => id,
        "object" => "checkout.session",
        "url" => checkout_url(id)
      })
    end)
  end

  @doc "Makes `POST /v1/checkout/sessions` fail with `status`."
  def fail_create(status) do
    StripeHTTPStub.stub("POST", "/v1/checkout/sessions", fn conn ->
      StripeHTTPStub.stripe_error(conn, status, %{"message" => "stubbed failure"})
    end)
  end

  @doc "Answers `GET /v1/checkout/sessions/<id>` with `session`."
  def stub_retrieve(%{"id" => id} = session) do
    StripeHTTPStub.stub("GET", "/v1/checkout/sessions/#{id}", fn conn ->
      StripeHTTPStub.json(conn, session)
    end)
  end

  @doc "Answers `POST /v1/checkout/sessions/<id>/expire` with the session, now expired."
  def stub_expire(%{"id" => id} = session) do
    StripeHTTPStub.stub("POST", "/v1/checkout/sessions/#{id}/expire", fn conn ->
      StripeHTTPStub.json(conn, Map.put(session, "status", "expired"))
    end)
  end

  @doc "Makes expiring a session fail as Stripe does for a session that is not open."
  def refuse_expire(session_id) do
    StripeHTTPStub.stub("POST", "/v1/checkout/sessions/#{session_id}/expire", fn conn ->
      StripeHTTPStub.stripe_error(conn, 400, %{
        "message" => "Only Checkout Sessions with a status of open can be expired."
      })
    end)
  end

  @doc "A Checkout Session object for a payment row: completed and paid unless overridden."
  def session(payment, overrides \\ %{})

  def session(%IntakePayment{} = row, overrides),
    do: session(row.id, Map.merge(%{"amount_total" => row.amount_cents}, overrides))

  def session(payment_id, overrides) when is_binary(payment_id) do
    Map.merge(
      %{
        "id" => session_id(payment_id),
        "object" => "checkout.session",
        "status" => "complete",
        "payment_status" => "paid",
        "amount_total" => 4000,
        "currency" => "eur",
        "payment_intent" => "pi_#{payment_id}",
        "metadata" => %{"type" => "beginners_intake_payment", "payment_id" => payment_id}
      },
      overrides
    )
  end

  # ── Refunds (ALE-382) ──────────────────────────────────────────

  @doc "The Stripe refund id a refund row's create answers with."
  def stripe_refund_id(%{id: id}), do: stripe_refund_id(id)
  def stripe_refund_id(refund_id) when is_binary(refund_id), do: "re_" <> refund_id

  @doc """
  Answers `POST /v1/refunds` with a refund in `status` whose id derives from
  the idempotency key (`beginners-intake-refund:<id>` → `re_<id>`), and
  sends `{:refund_created, form, idempotency_key}` to `notify`.
  """
  def stub_refund_create(status \\ "pending", notify \\ self()) do
    StripeHTTPStub.stub("POST", "/v1/refunds", fn conn ->
      key = StripeHTTPStub.header(conn, "idempotency-key")
      form = StripeHTTPStub.form(conn)
      send(notify, {:refund_created, form, key})
      refund_id = key |> String.split(":") |> List.last()

      StripeHTTPStub.json(
        conn,
        refund_object(refund_id, %{
          "status" => status,
          "amount" => String.to_integer(form["amount"]),
          "payment_intent" => form["payment_intent"]
        })
      )
    end)
  end

  @doc "Makes `POST /v1/refunds` fail with `status`."
  def fail_refund_create(status) do
    StripeHTTPStub.stub("POST", "/v1/refunds", fn conn ->
      StripeHTTPStub.stripe_error(conn, status, %{"message" => "stubbed refund failure"})
    end)
  end

  @doc "Answers `GET /v1/refunds/<id>` with `object`."
  def stub_refund_retrieve(%{"id" => id} = object) do
    StripeHTTPStub.stub("GET", "/v1/refunds/#{id}", fn conn ->
      StripeHTTPStub.json(conn, object)
    end)
  end

  @doc "A Stripe refund object for a refund row id, `succeeded` unless overridden."
  def refund_object(refund_id, overrides \\ %{}) when is_binary(refund_id) do
    Map.merge(
      %{
        "id" => stripe_refund_id(refund_id),
        "object" => "refund",
        "status" => "succeeded",
        "amount" => 4000,
        "currency" => "eur",
        "metadata" => %{"type" => "beginners_intake_refund", "refund_id" => refund_id}
      },
      overrides
    )
  end

  # ── Original payments of imported Carried Fees (ALE-389) ───────

  @doc """
  Answers `GET /v1/payment_intents/<id>` with a `succeeded` PaymentIntent
  that took `amount` (overridable), its latest charge expanded.
  """
  def stub_payment_intent(id, overrides \\ %{}) do
    object =
      Map.merge(
        %{
          "id" => id,
          "object" => "payment_intent",
          "status" => "succeeded",
          "amount" => 4000,
          "amount_received" => 4000,
          "currency" => "eur",
          "latest_charge" => %{"id" => "ch_" <> id, "amount_refunded" => 0}
        },
        overrides
      )

    StripeHTTPStub.stub("GET", "/v1/payment_intents/#{id}", fn conn ->
      StripeHTTPStub.json(conn, object)
    end)
  end

  @doc "Makes `GET /v1/payment_intents/<id>` fail with `status`."
  def fail_payment_intent(id, status) do
    StripeHTTPStub.stub("GET", "/v1/payment_intents/#{id}", fn conn ->
      StripeHTTPStub.stripe_error(conn, status, %{"message" => "No such payment_intent"})
    end)
  end

  @doc "A Stripe webhook event carrying `object`."
  def event(type, object),
    do: %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => type,
      "data" => %{"object" => object}
    }
end
