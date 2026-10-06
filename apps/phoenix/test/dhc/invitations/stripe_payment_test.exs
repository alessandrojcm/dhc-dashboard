defmodule Dhc.Invitations.StripePaymentTest do
  use ExUnit.Case, async: true

  alias Dhc.Invitations.StripePayment
  alias Dhc.StripeHTTPStub

  test "reuses the customer identified by acceptance-attempt metadata" do
    StripeHTTPStub.expect("GET", "/v1/customers", fn conn ->
      assert StripeHTTPStub.query(conn)["email"] == "member@example.com"
      assert StripeHTTPStub.query(conn)["limit"] == "100"

      stripe_json(conn, %{
        "object" => "list",
        "has_more" => false,
        "data" => [
          %{
            "id" => "cus_same_email",
            "metadata" => %{"acceptance_attempt_id" => "another-attempt"}
          },
          %{
            "id" => "cus_recovered",
            "metadata" => %{"acceptance_attempt_id" => "attempt-123"}
          }
        ]
      })
    end)

    assert {:ok, "cus_recovered"} =
             StripePayment.create_customer(
               "member@example.com",
               "Member Name",
               "inviter-123",
               "attempt-123"
             )
  end

  test "creates a customer with stable attempt metadata when no match exists" do
    StripeHTTPStub.expect("GET", "/v1/customers", fn conn ->
      stripe_json(conn, %{"object" => "list", "has_more" => false, "data" => []})
    end)

    StripeHTTPStub.expect("POST", "/v1/customers", fn conn ->
      params = StripeHTTPStub.form(conn)

      assert params["email"] == "member@example.com"
      assert params["name"] == "Member Name"
      assert params["metadata[invited_by]"] == "inviter-123"
      assert params["metadata[acceptance_attempt_id]"] == "attempt-123"

      assert ["invitation-accept:attempt-123:customer"] =
               Plug.Conn.get_req_header(conn, "idempotency-key")

      stripe_json(conn, %{"id" => "cus_created"})
    end)

    assert {:ok, "cus_created"} =
             StripePayment.create_customer(
               "member@example.com",
               "Member Name",
               "inviter-123",
               "attempt-123"
             )
  end

  test "continues creating subscriptions when the monthly SEPA payment is processing" do
    test_process = self()

    StripeHTTPStub.stub("POST", "/v1/subscriptions", fn conn ->
      params = StripeHTTPStub.form(conn)

      case params["metadata[acceptance_kind]"] do
        "monthly" ->
          send(test_process, {:subscription_created, :monthly})

          stripe_json(conn, %{
            "id" => "sub_monthly",
            "latest_invoice" => %{
              "id" => "in_monthly",
              "status" => "open",
              "payments" => %{
                "data" => [%{"payment" => %{"payment_intent" => "pi_monthly"}}]
              }
            }
          })

        "annual" ->
          send(test_process, {:subscription_created, :annual})

          stripe_json(conn, %{
            "id" => "sub_annual",
            "latest_invoice" => %{
              "id" => "in_annual",
              "status" => "paid",
              "payments" => %{"data" => []}
            }
          })
      end
    end)

    StripeHTTPStub.expect("GET", "/v1/payment_intents/pi_monthly", fn conn ->
      stripe_json(conn, %{"id" => "pi_monthly", "status" => "processing"})
    end)

    plan = %{
      monthly_price_id: "price_monthly",
      annual_price_id: "price_annual",
      coupon_id: nil,
      migration?: false,
      promotion_code_id: nil,
      requirement: :paid
    }

    assert {:pending, %{"payment_intent_status" => "processing"}} =
             StripePayment.complete(%{
               customer_id: "cus_member",
               payment_method_id: "pm_sepa",
               attempt_id: "attempt-123",
               payment_plan: plan
             })

    assert_received {:subscription_created, :monthly}
    assert_received {:subscription_created, :annual}
  end

  test "applies a private coupon ID directly to complimentary tier subscriptions" do
    test_process = self()

    StripeHTTPStub.stub("POST", "/v1/subscriptions", fn conn ->
      params = StripeHTTPStub.form(conn)

      send(test_process, {
        :tier_subscription_created,
        params["metadata[acceptance_kind]"],
        params["discounts[0][coupon]"],
        params["discounts[0][promotion_code]"]
      })

      stripe_json(conn, %{
        "id" => "sub_#{params["metadata[acceptance_kind]"]}",
        "latest_invoice" => %{
          "id" => "in_#{params["metadata[acceptance_kind]"]}",
          "status" => "paid",
          "amount_due" => 0,
          "payments" => %{"data" => []}
        }
      })
    end)

    plan = %{
      monthly_price_id: "price_monthly",
      annual_price_id: "price_annual",
      coupon_id: "DHC_COACH_TIER",
      migration?: false,
      promotion_code_id: nil,
      requirement: :complimentary,
      discount_targets: [:monthly, :annual]
    }

    assert :ok =
             StripePayment.complete(%{
               complimentary: true,
               customer_id: "cus_coach",
               attempt_id: "attempt-coach",
               payment_plan: plan
             })

    assert_received {:tier_subscription_created, "monthly", "DHC_COACH_TIER", nil}
    assert_received {:tier_subscription_created, "annual", "DHC_COACH_TIER", nil}
  end

  test "skips subscription discovery when cleanup state has no Stripe customer" do
    # No Stripe route is registered, so any Stripe call would raise; a passing
    # assertion proves discovery was skipped for attempts that never created a
    # customer.

    assert :ok = StripePayment.cancel_membership(%{"customer_id" => nil, "other" => "ignored"})
    assert :ok = StripePayment.cancel_membership(%{"customer_id" => ""})
  end

  test "still cancels known subscriptions when cleanup state has no Stripe customer" do
    test_process = self()

    StripeHTTPStub.expect("DELETE", "/v1/subscriptions/sub_monthly", fn conn ->
      send(test_process, :subscription_cancelled)
      stripe_json(conn, %{"id" => "sub_monthly", "status" => "canceled"})
    end)

    assert :ok =
             StripePayment.cancel_membership(%{
               "customer_id" => nil,
               "monthly_subscription_id" => "sub_monthly"
             })

    assert_received :subscription_cancelled
  end

  defp stripe_json(conn, body), do: StripeHTTPStub.json(conn, body)
end
