defmodule Dhc.StripeSyncTest do
  use ExUnit.Case, async: true

  alias Dhc.StripeSync

  describe "resolve_last_payment_date/1" do
    test "uses paid_at from latest_invoice status_transitions when available" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => %{
          "status_transitions" => %{
            "paid_at" => 1_710_000_000
          }
        }
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert %DateTime{} = result
      assert result == DateTime.from_unix!(1_710_000_000)
    end

    test "falls back to start_date when paid_at is nil" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => %{
          "status_transitions" => %{
            "paid_at" => nil
          }
        }
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert %DateTime{} = result
      assert result == DateTime.from_unix!(1_700_000_000)
    end

    test "falls back to start_date when latest_invoice is nil" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => nil
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert %DateTime{} = result
      assert result == DateTime.from_unix!(1_700_000_000)
    end

    test "returns nil when both paid_at and start_date are nil" do
      subscription = %{
        "status" => "active",
        "start_date" => nil,
        "latest_invoice" => nil
      }

      assert StripeSync.resolve_last_payment_date(subscription) == nil
    end

    test "returns nil when latest_invoice is a string (not expanded)" do
      subscription = %{
        "status" => "active",
        "start_date" => nil,
        "latest_invoice" => "in_12345"
      }

      # String latest_invoice → safe_get_in returns nil → falls through to nil start_date → nil
      assert StripeSync.resolve_last_payment_date(subscription) == nil
    end

    test "falls back to start_date when latest_invoice is a string" do
      subscription = %{
        "status" => "active",
        "start_date" => 1_700_000_000,
        "latest_invoice" => "in_12345"
      }

      result = StripeSync.resolve_last_payment_date(subscription)

      assert result == DateTime.from_unix!(1_700_000_000)
    end
  end

  describe "get_target_customer_ids/1" do
    test "deduplicates and trims manually provided customer IDs" do
      ids = [" cus_abc ", "cus_def", "cus_abc", "", "  "]

      result = StripeSync.get_target_customer_ids(ids)

      assert result == ["cus_abc", "cus_def"]
    end

    test "returns deduplicated list preserving order" do
      ids = ["cus_a", "cus_b", "cus_a"]

      result = StripeSync.get_target_customer_ids(ids)

      assert result == ["cus_a", "cus_b"]
    end

    test "filters out empty strings after trimming" do
      ids = ["cus_a", "  ", "", "cus_b"]

      result = StripeSync.get_target_customer_ids(ids)

      assert result == ["cus_a", "cus_b"]
    end
  end

  describe "req_stripe_subscriptions/1 with Bypass" do
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

    test "returns subscription data on success", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/subscriptions", fn conn ->
        # Assert Stripe-Version header is sent
        assert ["2025-10-29.clover"] = Plug.Conn.get_req_header(conn, "stripe-version")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [
              %{
                "id" => "sub_123",
                "customer" => "cus_abc",
                "created" => 1_710_000_000,
                "status" => "active"
              }
            ],
            "has_more" => false
          })
        )
      end)

      params = %{status: "all", price: "price_abc", limit: 100}

      assert {:ok, %{"data" => [_ | _]}} = StripeSync.req_stripe_subscriptions(params)
    end

    test "returns error when Stripe API returns non-2xx", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/subscriptions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{"error" => %{"message" => "Invalid API key"}})
        )
      end)

      params = %{status: "all", price: "price_abc", limit: 100}

      assert {:error, {:stripe_api, 401}} = StripeSync.req_stripe_subscriptions(params)
    end

    test "returns error when Stripe key is not configured" do
      Application.put_env(:dhc, :stripe_secret_key, nil)

      params = %{status: "all", price: "price_abc", limit: 100}

      assert {:error, :stripe_key_not_configured} = StripeSync.req_stripe_subscriptions(params)
    after
      Application.put_env(:dhc, :stripe_secret_key, "sk_test_123")
    end

    test "returns error on HTTP connection failure" do
      Application.put_env(:dhc, :stripe_api_url, "http://localhost:1")

      params = %{status: "all", price: "price_abc", limit: 100}

      assert {:error, {:http_error, _}} = StripeSync.req_stripe_subscriptions(params)
    after
      Application.put_env(:dhc, :stripe_api_url, "https://api.stripe.com")
    end
  end

  describe "req_stripe_prices/1 with Bypass" do
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

    test "returns price data on success", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/prices", fn conn ->
        # Assert Stripe-Version header is sent
        assert ["2025-10-29.clover"] = Plug.Conn.get_req_header(conn, "stripe-version")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "object" => "list",
            "data" => [%{"id" => "price_abc123", "lookup_key" => "standard_membership_fee"}]
          })
        )
      end)

      params = "lookup_keys[]=standard_membership_fee&active=true&limit=1"

      assert {:ok, %{"data" => [_ | _]}} = StripeSync.req_stripe_prices(params)
    end

    test "returns error when Stripe API returns non-2xx", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1/prices", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => %{"message" => "Forbidden"}}))
      end)

      params = "lookup_keys[]=standard_membership_fee&active=true&limit=1"

      assert {:error, {:stripe_api, 403}} = StripeSync.req_stripe_prices(params)
    end

    test "returns error when Stripe key is not configured" do
      Application.put_env(:dhc, :stripe_secret_key, nil)

      params = "lookup_keys[]=standard_membership_fee&active=true&limit=1"

      assert {:error, :stripe_key_not_configured} = StripeSync.req_stripe_prices(params)
    after
      Application.put_env(:dhc, :stripe_secret_key, "sk_test_123")
    end
  end

  describe "config accessors" do
    test "stripe_api_url returns default when not configured" do
      Application.delete_env(:dhc, :stripe_api_url)

      assert StripeSync.stripe_api_url() == "https://api.stripe.com"
    after
      Application.put_env(:dhc, :stripe_api_url, "https://stripe.example.com")
    end

    test "stripe_api_url returns configured value" do
      Application.put_env(:dhc, :stripe_api_url, "https://custom.stripe.api")

      assert StripeSync.stripe_api_url() == "https://custom.stripe.api"
    after
      Application.put_env(:dhc, :stripe_api_url, "https://stripe.example.com")
    end

    test "stripe_api_version returns default when not configured" do
      Application.delete_env(:dhc, :stripe_api_version)

      assert StripeSync.stripe_api_version() == "2025-10-29.clover"
    after
      Application.put_env(:dhc, :stripe_api_version, "2025-10-29.clover")
    end

    test "stripe_api_version returns configured value" do
      Application.put_env(:dhc, :stripe_api_version, "2024-01-01.acacia")

      assert StripeSync.stripe_api_version() == "2024-01-01.acacia"
    after
      Application.put_env(:dhc, :stripe_api_version, "2025-10-29.clover")
    end
  end
end
