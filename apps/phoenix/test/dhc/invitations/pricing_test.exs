defmodule Dhc.Invitations.PricingTest do
  use ExUnit.Case, async: false

  alias Dhc.Invitations.Pricing

  setup do
    bypass = Bypass.open()
    original_url = Application.get_env(:dhc, :stripe_api_url)
    original_key = Application.get_env(:dhc, :stripe_secret_key)

    Application.put_env(:dhc, :stripe_api_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dhc, :stripe_secret_key, "sk_test_123")

    on_exit(fn ->
      Application.put_env(:dhc, :stripe_api_url, original_url)
      Application.put_env(:dhc, :stripe_secret_key, original_key)
    end)

    {:ok, bypass: bypass}
  end

  test "a missing backend-applied tier coupon degrades to tier_coupon_not_configured", %{
    bypass: bypass
  } do
    # Regression for the 2026-08-24 coach-invitation incident: STRIPE_COACH_COUPON_ID
    # pointed at a coupon name instead of its live coupon ID, so retrieval 404'd,
    # the failure was treated as a provider error, and cleanup retries stormed Stripe.
    stub_membership_prices(bypass)

    Bypass.expect_once(bypass, "GET", "/v1/coupons/DHC_COACH_TIER", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        404,
        Jason.encode!(%{
          "error" => %{
            "code" => "resource_missing",
            "type" => "invalid_request_error",
            "message" => "No such coupon: 'DHC_COACH_TIER'",
            "param" => "coupon"
          }
        })
      )
    end)

    assert {:error, :tier_coupon_not_configured} =
             Pricing.membership_payment_plan({:coupon, "DHC_COACH_TIER", [:monthly, :annual]})
  end

  test "other Stripe failures from tier coupon retrieval pass through unchanged", %{
    bypass: bypass
  } do
    stub_membership_prices(bypass)

    Bypass.expect_once(bypass, "GET", "/v1/coupons/DHC_STUDENT_TIER", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"type" => "api_error"}}))
    end)

    assert {:error, {:stripe, {:stripe_api, 500, %{"error" => %{"type" => "api_error"}}}}} =
             Pricing.membership_payment_plan({:coupon, "DHC_STUDENT_TIER", [:monthly]})
  end

  defp stub_membership_prices(bypass) do
    # The monthly and annual membership prices are resolved by lookup key
    # before any tier coupon is retrieved.
    Bypass.expect(bypass, "GET", "/v1/prices", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "object" => "list",
          "has_more" => false,
          "data" => [
            %{
              "id" => "price_#{conn.query_params["lookup_keys[]"]}",
              "product" => "prod_membership"
            }
          ]
        })
      )
    end)
  end
end
