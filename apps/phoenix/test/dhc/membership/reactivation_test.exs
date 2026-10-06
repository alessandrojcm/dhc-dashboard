defmodule Dhc.Membership.ReactivationTest do
  @moduledoc """
  Deterministic `Dhc.Membership.Reactivation.activate/1` suite (ALE-342).

  Stripe is stubbed at the one transport seam (`Req.Test` under `Dhc.Stripe`),
  so the real request encoding, idempotency keys and response decoding run
  without `--include integration`. The real-Stripe behaviour (billing anchors,
  SEPA settlement) stays covered by `Dhc.Membership.ReactivationIntegrationTest`.
  """

  use ExUnit.Case, async: true

  alias Dhc.Membership.Reactivation
  alias Dhc.Stripe.LookupKeys
  alias Dhc.StripeHTTPStub

  @moduletag :capture_log

  @customer_id "cus_reactivate"
  @member_id "11111111-1111-1111-1111-111111111111"

  setup do
    StripeHTTPStub.stub("GET", "/v1/customers/#{@customer_id}/payment_methods", fn conn ->
      assert StripeHTTPStub.query(conn)["type"] == "sepa_debit"
      StripeHTTPStub.json(conn, %{"object" => "list", "data" => [%{"id" => "pm_saved"}]})
    end)

    StripeHTTPStub.stub("GET", "/v1/prices", fn conn ->
      price_id =
        if StripeHTTPStub.query(conn)["lookup_keys[]"] == LookupKeys.monthly(),
          do: "price_monthly",
          else: "price_annual"

      StripeHTTPStub.json(conn, %{"object" => "list", "data" => [%{"id" => price_id}]})
    end)

    :ok
  end

  describe "activate/1 success" do
    test "creates both subscriptions on the saved method and confirms each first invoice" do
      test_pid = self()

      stub_subscriptions(fn kind, params ->
        send(test_pid, {:subscription, kind, params})
        incomplete_subscription(kind, "pi_#{kind}")
      end)

      stub_confirm(fn payment_intent_id, params ->
        send(test_pid, {:confirmed, payment_intent_id, params})
        %{"id" => payment_intent_id, "status" => "succeeded"}
      end)

      assert {:ok,
              %{
                memberId: @member_id,
                paymentState: "succeeded",
                monthlySubscriptionId: "sub_monthly",
                annualSubscriptionId: "sub_annual"
              }} = activate()

      assert_received {:subscription, "monthly", monthly}
      assert monthly["customer"] == @customer_id
      assert monthly["items[0][price]"] == "price_monthly"
      assert monthly["payment_behavior"] == "default_incomplete"
      assert monthly["collection_method"] == "charge_automatically"
      assert monthly["expand[]"] == "latest_invoice.payments"
      assert monthly["default_payment_method"] == "pm_saved"
      assert monthly["metadata[purpose]"] == "membership-reactivation"
      assert monthly["metadata[member_id]"] == @member_id
      assert Map.has_key?(monthly, "billing_cycle_anchor")

      assert_received {:subscription, "annual", annual}
      assert annual["items[0][price]"] == "price_annual"
      assert annual["billing_cycle_anchor_config[month]"] == "1"
      assert annual["billing_cycle_anchor_config[day_of_month]"] == "7"

      for payment_intent_id <- ["pi_monthly", "pi_annual"] do
        assert_received {:confirmed, ^payment_intent_id, params}
        assert params["payment_method"] == "pm_saved"
        assert params["mandate_data[customer_acceptance][type]"] == "offline"
      end
    end

    test "accepts a first invoice that is already paid and carries no PaymentIntent" do
      stub_subscriptions(fn kind, _params -> paid_subscription(kind) end)

      assert {:ok, %{paymentState: "succeeded"}} = activate()
    end

    test "reads a PaymentIntent embedded as an object in the invoice payment" do
      stub_subscriptions(fn kind, _params ->
        put_in(
          incomplete_subscription(kind, nil),
          ["latest_invoice", "payments", "data"],
          [%{"payment" => %{"payment_intent" => %{"id" => "pi_#{kind}_embedded"}}}]
        )
      end)

      stub_confirm(fn id, _params -> %{"id" => id, "status" => "succeeded"} end)

      assert {:ok, %{paymentState: "succeeded"}} = activate()
    end
  end

  describe "activate/1 pending PaymentIntent states" do
    test "reports SEPA processing as pending and still creates the annual subscription" do
      stub_subscriptions(fn kind, _params -> incomplete_subscription(kind, "pi_#{kind}") end)

      stub_confirm(fn
        "pi_monthly" = id, _params -> %{"id" => id, "status" => "processing"}
        id, _params -> %{"id" => id, "status" => "succeeded"}
      end)

      assert {:ok, %{paymentState: "pending", annualSubscriptionId: "sub_annual"}} = activate()
    end

    for {status, payment_state} <- [
          {"requires_action", "needs_action"},
          {"requires_payment_method", "terminal"},
          {"canceled", "terminal"},
          {"requires_confirmation", "terminal"},
          {"some_future_status", "terminal"}
        ] do
      test "maps a confirmed #{status} PaymentIntent to #{payment_state}" do
        stub_subscriptions(fn kind, _params -> incomplete_subscription(kind, "pi_#{kind}") end)

        stub_confirm(fn id, _params ->
          %{"id" => id, "status" => unquote(status), "next_action" => %{"type" => "redirect"}}
        end)

        assert {:ok, %{paymentState: unquote(payment_state)}} = activate()
      end
    end
  end

  describe "activate/1 unsettled first invoices" do
    test "fails when the first invoice has no PaymentIntent and is not paid" do
      stub_subscriptions(fn kind, _params ->
        put_in(paid_subscription(kind), ["latest_invoice", "status"], "open")
      end)

      assert {:error, :stripe_error} = activate()
    end

    test "fails when the subscription carries no expanded invoice" do
      stub_subscriptions(fn kind, _params ->
        %{"id" => "sub_#{kind}", "latest_invoice" => nil}
      end)

      assert {:error, :stripe_error} = activate()
    end
  end

  describe "activate/1 Stripe errors" do
    test "reports a missing saved SEPA method distinctly" do
      StripeHTTPStub.stub("GET", "/v1/customers/#{@customer_id}/payment_methods", fn conn ->
        StripeHTTPStub.json(conn, %{"object" => "list", "data" => []})
      end)

      assert {:error, :no_saved_payment_method} = activate()
    end

    test "collapses a subscription creation failure into stripe_error" do
      StripeHTTPStub.expect("POST", "/v1/subscriptions", fn conn ->
        StripeHTTPStub.stripe_error(conn, 500, %{"message" => "boom"})
      end)

      assert {:error, :stripe_error} = activate()
    end

    test "collapses a confirmation failure into stripe_error" do
      stub_subscriptions(fn kind, _params -> incomplete_subscription(kind, "pi_#{kind}") end)

      StripeHTTPStub.expect("POST", "/v1/payment_intents/pi_monthly/confirm", fn conn ->
        StripeHTTPStub.stripe_error(conn, 402, %{"code" => "payment_intent_unexpected_state"})
      end)

      assert {:error, :stripe_error} = activate()
    end

    test "collapses a transport failure into stripe_error" do
      StripeHTTPStub.expect("POST", "/v1/subscriptions", fn conn ->
        StripeHTTPStub.transport_error(conn, :timeout)
      end)

      assert {:error, :stripe_error} = activate()
    end
  end

  describe "activate/1 idempotency" do
    test "replays every mutating call under the same keys, so Stripe dedupes the retry" do
      test_pid = self()

      stub_subscriptions(fn kind, _params, conn ->
        send(test_pid, {:key, StripeHTTPStub.header(conn, "idempotency-key")})
        incomplete_subscription(kind, "pi_#{kind}")
      end)

      StripeHTTPStub.stub(
        "POST",
        "/v1/payment_intents/pi_monthly/confirm",
        &confirm_ok(&1, test_pid)
      )

      StripeHTTPStub.stub(
        "POST",
        "/v1/payment_intents/pi_annual/confirm",
        &confirm_ok(&1, test_pid)
      )

      assert {:ok, first} = activate()
      first_keys = drain_keys()

      assert {:ok, ^first} = activate()
      assert drain_keys() == first_keys

      prefix = "membership-reactivate:#{@member_id}:#{Date.to_iso8601(Date.utc_today())}"

      assert first_keys == [
               "#{prefix}:prorated_now:subscription-monthly",
               "#{prefix}:prorated_now:payment-intent-pi_monthly",
               "#{prefix}:prorated_now:subscription-annual",
               "#{prefix}:prorated_now:payment-intent-pi_annual"
             ]
    end

    test "scopes keys by annual fee mode" do
      test_pid = self()

      stub_subscriptions(fn kind, _params, conn ->
        send(test_pid, {:key, StripeHTTPStub.header(conn, "idempotency-key")})
        incomplete_subscription(kind, "pi_#{kind}")
      end)

      StripeHTTPStub.stub(
        "POST",
        "/v1/payment_intents/pi_monthly/confirm",
        &confirm_ok(&1, test_pid)
      )

      assert {:ok, _result} = activate(annual_fee_mode: :deferred_next_year)

      assert Enum.all?(drain_keys(), &String.contains?(&1, ":deferred_next_year:"))
    end
  end

  defp activate(overrides \\ []) do
    %{customer_id: @customer_id, member_id: @member_id, start_date: Date.utc_today()}
    |> Map.merge(Map.new(overrides))
    |> Reactivation.activate()
  end

  defp stub_subscriptions(fun) when is_function(fun, 2),
    do: stub_subscriptions(fn kind, params, _conn -> fun.(kind, params) end)

  defp stub_subscriptions(fun) when is_function(fun, 3) do
    StripeHTTPStub.stub("POST", "/v1/subscriptions", fn conn ->
      params = StripeHTTPStub.form(conn)
      StripeHTTPStub.json(conn, fun.(params["metadata[kind]"], params, conn))
    end)
  end

  defp stub_confirm(fun) do
    for id <- ["pi_monthly", "pi_annual", "pi_monthly_embedded", "pi_annual_embedded"] do
      StripeHTTPStub.stub("POST", "/v1/payment_intents/#{id}/confirm", fn conn ->
        StripeHTTPStub.json(conn, fun.(id, StripeHTTPStub.form(conn)))
      end)
    end
  end

  defp confirm_ok(conn, test_pid) do
    send(test_pid, {:key, StripeHTTPStub.header(conn, "idempotency-key")})
    [_, _, _, id, "confirm"] = String.split(conn.request_path, "/")
    StripeHTTPStub.json(conn, %{"id" => id, "status" => "succeeded"})
  end

  defp drain_keys(keys \\ []) do
    receive do
      {:key, key} -> drain_keys([key | keys])
    after
      0 -> Enum.reverse(keys)
    end
  end

  defp incomplete_subscription(kind, payment_intent_id) do
    %{
      "id" => "sub_#{kind}",
      "status" => "incomplete",
      "latest_invoice" => %{
        "id" => "in_#{kind}",
        "status" => "open",
        "payments" => %{
          "data" => [%{"payment" => %{"payment_intent" => payment_intent_id}}]
        }
      }
    }
  end

  defp paid_subscription(kind) do
    %{
      "id" => "sub_#{kind}",
      "status" => "active",
      "latest_invoice" => %{
        "id" => "in_#{kind}",
        "status" => "paid",
        "payments" => %{"data" => []}
      }
    }
  end
end
