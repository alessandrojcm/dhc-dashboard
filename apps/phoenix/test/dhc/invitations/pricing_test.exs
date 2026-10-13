defmodule Dhc.Invitations.PricingTest do
  use ExUnit.Case, async: true

  alias Dhc.Invitations.Pricing
  alias Dhc.Invitations.StripePayment
  alias Dhc.Stripe.LookupKeys
  alias Dhc.StripeHTTPStub

  describe "billing anchors (ALE-423)" do
    # The subscription sends a config Stripe resolves at creation; the preview
    # must send the anchor that config resolves to at the same instant, and the
    # dates the person is shown must be that anchor's date.
    for {label, now} <- [
          {"31 December", ~U[2026-12-31 22:15:09Z]},
          {"3 January", ~U[2027-01-03 08:00:00Z]},
          {"7 January itself", ~U[2027-01-07 12:00:00Z]},
          {"mid-year", ~U[2026-07-15 17:45:30Z]}
        ] do
      @now now
      test "the preview anchors where subscription creation will, on #{label}" do
        configs = subscription_anchor_configs()
        {pricing, previews} = preview_anchors(@now)

        for kind <- [:monthly, :annual] do
          expected = stripe_resolves(Map.fetch!(configs, kind), @now)

          assert previews[{kind, "billing_cycle_anchor"}] == DateTime.to_unix(expected),
                 "#{kind} initial preview anchor differs from the subscription's"

          assert previews[{kind, "start_date"}] == DateTime.to_unix(expected),
                 "#{kind} recurring preview anchor differs from the subscription's"
        end

        assert pricing.monthlyBillingStart ==
                 Date.to_iso8601(DateTime.to_date(stripe_resolves(configs.monthly, @now)))

        assert pricing.annualBillingStart ==
                 Date.to_iso8601(DateTime.to_date(stripe_resolves(configs.annual, @now)))
      end
    end

    test "the complimentary preview carries the same billing start dates" do
      assert %{monthlyBillingStart: "2027-02-01", annualBillingStart: "2027-01-07"} =
               Pricing.complimentary_preview(~U[2027-01-03 08:00:00Z])
    end
  end

  test "a missing backend-applied tier coupon degrades to tier_coupon_not_configured" do
    # Regression for the 2026-08-24 coach-invitation incident: STRIPE_COACH_COUPON_ID
    # pointed at a coupon name instead of its live coupon ID, so retrieval 404'd,
    # the failure was treated as a provider error, and cleanup retries stormed Stripe.
    stub_membership_prices()

    StripeHTTPStub.expect("GET", "/v1/coupons/DHC_COACH_TIER", fn conn ->
      StripeHTTPStub.stripe_error(conn, 404, %{
        "code" => "resource_missing",
        "message" => "No such coupon: 'DHC_COACH_TIER'",
        "param" => "coupon"
      })
    end)

    assert {:error, :tier_coupon_not_configured} =
             Pricing.membership_payment_plan({:coupon, "DHC_COACH_TIER", [:monthly, :annual]})
  end

  test "other Stripe failures from tier coupon retrieval pass through unchanged" do
    stub_membership_prices()

    StripeHTTPStub.expect("GET", "/v1/coupons/DHC_STUDENT_TIER", fn conn ->
      StripeHTTPStub.json(conn, 500, %{"error" => %{"type" => "api_error"}})
    end)

    assert {:error, {:stripe, {:stripe_api, 500, %{"error" => %{"type" => "api_error"}}}}} =
             Pricing.membership_payment_plan({:coupon, "DHC_STUDENT_TIER", [:monthly]})
  end

  defp stub_membership_prices do
    # The monthly and annual membership prices are resolved by lookup key
    # before any tier coupon is retrieved.
    StripeHTTPStub.stub("GET", "/v1/prices", fn conn ->
      StripeHTTPStub.json(conn, %{
        "object" => "list",
        "has_more" => false,
        "data" => [
          %{
            "id" => "price_#{StripeHTTPStub.query(conn)["lookup_keys[]"]}",
            "product" => "prod_membership"
          }
        ]
      })
    end)
  end

  # Captures the billing_cycle_anchor_config fields subscription creation sends.
  defp subscription_anchor_configs do
    test_process = self()

    StripeHTTPStub.stub("POST", "/v1/subscriptions", fn conn ->
      params = StripeHTTPStub.form(conn)
      kind = params["metadata[acceptance_kind]"]

      config =
        for {"billing_cycle_anchor_config[" <> key, value} <- params,
            into: %{},
            do: {String.trim_trailing(key, "]"), String.to_integer(value)}

      send(test_process, {:anchor_config, String.to_existing_atom(kind), config})

      StripeHTTPStub.json(conn, %{
        "id" => "sub_#{kind}",
        "latest_invoice" => %{
          "id" => "in_#{kind}",
          "status" => "paid",
          "payments" => %{"data" => []}
        }
      })
    end)

    assert :ok =
             StripePayment.complete(%{
               customer_id: "cus_member",
               payment_method_id: "pm_sepa",
               attempt_id: "attempt-anchors",
               payment_plan: %{
                 monthly_price_id: "price_monthly",
                 annual_price_id: "price_annual",
                 coupon_id: nil,
                 migration?: false,
                 promotion_code_id: nil,
                 requirement: :paid
               }
             })

    assert_received {:anchor_config, :monthly, monthly}
    assert_received {:anchor_config, :annual, annual}
    %{monthly: monthly, annual: annual}
  end

  # Stripe's resolution of billing_cycle_anchor_config, written independently of
  # the code under test: the first later day matching the config, at the
  # creation instant's UTC time-of-day.
  defp stripe_resolves(config, now) do
    time = %{DateTime.to_time(now) | microsecond: {0, 0}}

    now
    |> DateTime.to_date()
    |> Date.add(1)
    |> Stream.iterate(&Date.add(&1, 1))
    |> Enum.find(fn date ->
      date.day == Map.fetch!(config, "day_of_month") and
        date.month == Map.get(config, "month", date.month)
    end)
    |> DateTime.new!(time, "Etc/UTC")
  end

  defp preview_anchors(now) do
    assert {:ok, pricing} = preview_at(now)
    {pricing, collect_preview_anchors(%{})}
  end

  defp collect_preview_anchors(acc) do
    receive do
      {:preview_anchor, kind, key, unix} ->
        collect_preview_anchors(Map.put(acc, {kind, key}, unix))
    after
      0 -> acc
    end
  end

  defp preview_at(now) do
    test_process = self()
    stub_membership_prices()
    monthly_price = "price_#{LookupKeys.monthly()}"

    StripeHTTPStub.stub("POST", "/v1/invoices/create_preview", fn conn ->
      params = StripeHTTPStub.form(conn)

      kind =
        if params["subscription_details[items][0][price]"] == monthly_price,
          do: :monthly,
          else: :annual

      for key <- ["billing_cycle_anchor", "start_date"],
          value = params["subscription_details[#{key}]"],
          do: send(test_process, {:preview_anchor, kind, key, String.to_integer(value)})

      StripeHTTPStub.json(conn, %{"amount_due" => 1000, "subtotal" => 1000})
    end)

    Pricing.preview_membership(nil, now)
  end
end
