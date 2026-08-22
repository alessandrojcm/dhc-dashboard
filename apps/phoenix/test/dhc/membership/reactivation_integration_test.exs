defmodule Dhc.Membership.ReactivationIntegrationTest do
  @moduledoc """
  End-to-end reactivation test against the real Stripe test API.

  Exercises what Bypass cannot: actual Stripe behaviour for future
  `billing_cycle_anchor` semantics, off-session confirmation of the first
  invoice WITHOUT mandate data against a saved SEPA method (mandate reuse),
  async SEPA settlement surfacing as a pending outcome, and idempotency-key
  replay dedupe.

  Requires a Stripe *test mode* secret key:

      cd apps/phoenix && \\
        STRIPE_SECRET_KEY=sk_test_... \\
        mix test test/dhc/membership/reactivation_integration_test.exs --include integration

  Tagged `:integration` so it is excluded from the normal test run.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Stripe.Client, as: StripeClient

  @moduletag :integration

  @stripe_api_url "https://api.stripe.com"
  # Valid-checksum German IBAN accepted by Stripe test mode for sepa_debit.
  @test_iban "DE89370400440532013000"

  defmodule AdminVerifier do
    def verify("admin-token") do
      {:ok,
       %{
         sub: Ecto.UUID.generate(),
         email: "admin@example.com",
         roles: ["admin"],
         raw: %{}
       }}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original_verifier = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, AdminVerifier)

    original_url = Application.get_env(:dhc, :stripe_api_url)
    original_key = Application.get_env(:dhc, :stripe_secret_key)

    stripe_secret_key =
      System.get_env("STRIPE_SECRET_KEY") ||
        raise """
        STRIPE_SECRET_KEY is required for #{__MODULE__}.

        Use a Stripe *test mode* secret key and run with:

            mix test #{__ENV__.file} --include integration
        """

    Application.put_env(
      :dhc,
      :stripe_api_url,
      System.get_env("STRIPE_API_URL", @stripe_api_url)
    )

    Application.put_env(:dhc, :stripe_secret_key, stripe_secret_key)

    on_exit(fn ->
      Application.put_env(:dhc, :auth_verifier, original_verifier)
      Application.put_env(:dhc, :stripe_api_url, original_url)
      Application.put_env(:dhc, :stripe_secret_key, original_key)
    end)

    :ok
  end

  test "reactivates an inactive member against real Stripe test mode" do
    run_id = "dhc-reactivate-#{System.unique_integer([:positive])}"
    customer = create_customer!(run_id)

    try do
      payment_method_id = attach_saved_sepa_method!(customer["id"])
      assert saved_sepa_methods(customer["id"]) == [payment_method_id]

      member =
        Dhc.MemberFixtures.member_fixture(
          is_active: false,
          customer_id: customer["id"],
          email: "#{run_id}@example.com"
        )

      start_date = Date.utc_today() |> Date.add(3)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => Date.to_iso8601(start_date)
        })

      assert %{"data" => data} = response = json_response(conn, 200)
      assert data["memberId"] == member.auth_user_id
      # SEPA settles asynchronously — succeeded or pending are both healthy.
      assert data["paymentState"] in ["succeeded", "pending"]

      assert_subscriptions_match_request(%{
        "monthly_subscription_id" => data["monthlySubscriptionId"],
        "annual_subscription_id" => data["annualSubscriptionId"],
        "customer_id" => customer["id"],
        "payment_method_id" => payment_method_id,
        "start_date" => start_date
      })

      # ── Idempotent replay ────────────────────────────────────────────
      # Identical params must hit the same Stripe idempotency keys so the
      # stored responses come back instead of duplicate subscriptions.
      retry_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => Date.to_iso8601(start_date)
        })

      assert %{"data" => replayed} = json_response(retry_conn, 200)
      assert replayed["monthlySubscriptionId"] == data["monthlySubscriptionId"]
      assert replayed["annualSubscriptionId"] == data["annualSubscriptionId"]

      # Exactly the same two memberships exist — no duplicates were charged.
      assert Enum.sort(membership_subscription_ids(customer["id"])) ==
               Enum.sort([
                 data["monthlySubscriptionId"],
                 data["annualSubscriptionId"]
               ])

      # ── Guard against live coverage ──────────────────────────────────
      conflict_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => Date.to_iso8601(Date.utc_today() |> Date.add(10))
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conflict_conn, 409)
      assert detail =~ "active"

      _ = response
    after
      cleanup_customer!(customer["id"])
    end
  end

  # ── Stripe fixtures ──────────────────────────────────────────────────

  # ALE-254: the operator modal previews amounts through Stripe invoice
  # previews before any charge. Against real Stripe we can prove the preview
  # is truthful: the projected due-today must equal what the subsequent
  # reactivation actually charges, and the recurring fees must equal the real
  # price unit amounts.
  test "previewed reactivation amounts match the actual Stripe charge" do
    run_id = "dhc-amounts-#{System.unique_integer([:positive])}"
    customer = create_customer!(run_id)

    try do
      attach_saved_sepa_method!(customer["id"])

      member =
        Dhc.MemberFixtures.member_fixture(
          is_active: false,
          customer_id: customer["id"],
          email: "#{run_id}@example.com"
        )

      start_date = Date.utc_today() |> Date.add(5)

      preview_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members/#{member.auth_user_id}/membership/reactivation-preview/amounts", %{
          "startDate" => Date.to_iso8601(start_date)
        })

      assert %{
               "data" => %{
                 "dueToday" => %{"amount" => due_today, "currency" => "EUR"},
                 "monthlyFee" => %{"amount" => monthly_fee, "currency" => "EUR"},
                 "annualFee" => %{"amount" => annual_fee, "currency" => "EUR"}
               }
             } = json_response(preview_conn, 200)

      price_ids = membership_price_ids!()

      assert monthly_fee == price_unit_amount!(price_ids.monthly)
      assert annual_fee == price_unit_amount!(price_ids.annual)
      assert due_today > 0

      charge_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => Date.to_iso8601(start_date)
        })

      assert %{"data" => data} = json_response(charge_conn, 200)

      monthly_invoice = fetch_subscription!(data["monthlySubscriptionId"])["latest_invoice"]
      annual_invoice = fetch_subscription!(data["annualSubscriptionId"])["latest_invoice"]

      actual_due_today =
        monthly_invoice["amount_due"] + annual_invoice["amount_due"]

      # Preview and creation happen seconds apart; second-based proration can
      # shift the rounded total by a cent at most.
      assert abs(due_today - actual_due_today) <= 2,
             "preview #{inspect(due_today)} vs actual charge #{inspect(actual_due_today)}"
    after
      cleanup_customer!(customer["id"])
    end
  end

  defp create_customer!(run_id) do
    stripe_request!(:post, "/v1/customers", %{
      "name" => "DHC Reactivation #{run_id}",
      "email" => "#{run_id}@example.com",
      "metadata[test_run]" => run_id
    })
  end

  # Creates AND confirms a SetupIntent with inline sepa_debit data, which
  # attaches the payment method to the customer and generates its mandate —
  # the same end state the signup flow leaves behind.
  defp attach_saved_sepa_method!(customer_id) do
    setup_intent =
      stripe_request!(:post, "/v1/setup_intents", %{
        "customer" => customer_id,
        "confirm" => "true",
        "usage" => "off_session",
        "payment_method_types[]" => "sepa_debit",
        "payment_method_data[type]" => "sepa_debit",
        "payment_method_data[billing_details][name]" => "DHC Reactivation Test Member",
        "payment_method_data[billing_details][email]" => "#{customer_id}@example.test",
        "payment_method_data[sepa_debit][iban]" => @test_iban,
        "mandate_data[customer_acceptance][type]" => "online",
        "mandate_data[customer_acceptance][online][ip_address]" => "127.0.0.1",
        "mandate_data[customer_acceptance][online][user_agent]" =>
          "dhc-membership-reactivation-integration-test"
      })

    payment_method_id =
      case setup_intent["payment_method"] do
        id when is_binary(id) -> id
        %{"id" => id} when is_binary(id) -> id
        other -> flunk("SetupIntent returned no payment method: #{inspect(other)}")
      end

    eventually(fn ->
      if payment_method_id in saved_sepa_methods(customer_id),
        do: {:ok, payment_method_id},
        else: :retry
    end)

    payment_method_id
  end

  defp saved_sepa_methods(customer_id) do
    case StripeClient.request(
           method: :get,
           url: "/v1/customers/#{URI.encode(customer_id)}/payment_methods",
           query: [type: "sepa_debit", limit: 10]
         ) do
      {:ok, %{"data" => methods}} -> Enum.map(methods, & &1["id"])
      {:error, reason} -> raise "Listing payment methods failed: #{inspect(reason)}"
    end
  end

  defp assert_subscriptions_match_request(expected) do
    monthly = fetch_subscription!(expected["monthly_subscription_id"])
    annual = fetch_subscription!(expected["annual_subscription_id"])

    price_ids = membership_price_ids!()

    # Both subscriptions charge the saved SEPA method off-session.
    Enum.each([monthly, annual], fn subscription ->
      assert subscription["default_payment_method"] == expected["payment_method_id"]

      assert get_in(subscription, ["items", "data", Access.at(0), "price", "id"]) in Map.values(
               price_ids
             )

      # The first invoice was raised immediately (prorated stub) and the
      # off-session confirmation submitted it for settlement.
      invoice = subscription["latest_invoice"]
      assert is_map(invoice)
      assert invoice["amount_due"] > 0
      assert invoice["status"] in ["open", "paid"]
    end)

    assert get_in(monthly, ["items", "data", Access.at(0), "price", "id"]) == price_ids.monthly
    assert get_in(annual, ["items", "data", Access.at(0), "price", "id"]) == price_ids.annual

    # Monthly honours the operator-chosen start date as the cycle anchor.
    expected_anchor = midnight_unix(expected["start_date"])
    assert monthly["billing_cycle_anchor"] == expected_anchor

    # Annual keeps signup semantics: anchored at the next January 7, at the
    # subscription's CREATION time-of-day UTC (verified against real Stripe —
    # billing_cycle_anchor_config inherits hour/minute/second from creation).
    expected_annual_anchor =
      creation_time_of_day(annual["created"], next_january_anchor(Date.utc_today()))

    assert abs(annual["billing_cycle_anchor"] - expected_annual_anchor) <= 60

    # Metadata identifies these as reactivation subscriptions.
    assert get_in(monthly, ["metadata", "purpose"]) == "membership-reactivation"
    assert get_in(monthly, ["metadata", "kind"]) == "monthly"
    assert get_in(annual, ["metadata", "kind"]) == "annual"
  end

  defp membership_subscription_ids(customer_id) do
    price_ids = membership_price_ids!()

    case StripeClient.request(
           method: :get,
           url: "/v1/subscriptions",
           query: [customer: customer_id, status: "all", limit: 100]
         ) do
      {:ok, %{"data" => subscriptions}} ->
        Enum.flat_map(subscriptions, fn subscription ->
          price_id = get_in(subscription, ["items", "data", Access.at(0), "price", "id"])

          if price_id in Map.values(price_ids), do: [subscription["id"]], else: []
        end)
        |> Enum.sort()

      {:error, reason} ->
        raise "Listing subscriptions failed: #{inspect(reason)}"
    end
  end

  defp fetch_subscription!(subscription_id) do
    case StripeClient.request(
           method: :get,
           url: "/v1/subscriptions/#{URI.encode(subscription_id)}",
           query: [expand: ["latest_invoice.payments"]]
         ) do
      {:ok, subscription} -> subscription
      {:error, reason} -> raise "Fetching subscription failed: #{inspect(reason)}"
    end
  end

  defp membership_price_ids! do
    %{
      monthly: price_for_lookup_key!("standard_membership_fee"),
      annual: price_for_lookup_key!("annual_membership_fee_revised")
    }
  end

  defp price_for_lookup_key!(lookup_key) do
    case StripeClient.request(
           method: :get,
           url: "/v1/prices",
           query: [lookup_keys: [lookup_key], active: true, limit: 1]
         ) do
      {:ok, %{"data" => [%{"id" => price_id}]}} -> price_id
      {:error, reason} -> raise "No active price for #{lookup_key}: #{inspect(reason)}"
    end
  end

  defp price_unit_amount!(price_id) do
    case StripeClient.request(method: :get, url: "/v1/prices/#{URI.encode(price_id)}") do
      {:ok, %{"unit_amount" => amount}} when is_integer(amount) -> amount
      {:error, reason} -> raise "Fetching price failed: #{inspect(reason)}"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp cleanup_customer!(customer_id) do
    case StripeClient.request(
           method: :get,
           url: "/v1/subscriptions",
           query: [customer: customer_id, status: "all", limit: 100]
         ) do
      {:ok, %{"data" => subscriptions}} ->
        Enum.each(subscriptions, fn %{"id" => id} -> maybe_cancel_subscription!(id) end)

      {:error, _reason} ->
        :ok
    end

    try do
      stripe_request!(:delete, "/v1/customers/#{URI.encode(customer_id)}")
    rescue
      _ -> :ok
    end
  end

  defp maybe_cancel_subscription!(subscription_id) do
    try do
      stripe_request!(:post, "/v1/subscriptions/#{URI.encode(subscription_id)}", %{
        "invoice_now" => "false",
        "prorate" => "false"
      })
    rescue
      _ -> :ok
    end
  end

  defp stripe_request!(method, path, body \\ nil) do
    case StripeClient.request(method: method, url: path, body: body) do
      {:ok, response} -> response
      {:error, reason} -> raise "Stripe test API request failed: #{inspect(reason)}"
    end
  end

  # Polls an external-system condition that cannot be awaited via messages.
  defp eventually(fun, remaining \\ 20)
  defp eventually(_fun, 0), do: flunk("Stripe fixture condition not met in time")

  defp eventually(fun, remaining) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        Process.sleep(500)
        eventually(fun, remaining - 1)
    end
  end

  defp midnight_unix(date) do
    date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
  end

  # billing_cycle_anchor_config anchors to the next occurrence of the config
  # date at the SUBSCRIPTION CREATION time-of-day UTC.
  defp creation_time_of_day(created_unix, date) do
    %DateTime{hour: hour, minute: minute, second: second} = DateTime.from_unix!(created_unix)

    date
    |> DateTime.new!(%Time{hour: hour, minute: minute, second: second}, "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp next_january_anchor(today) do
    candidate = Date.new!(today.year, 1, 7)

    if Date.compare(candidate, today) == :gt,
      do: candidate,
      else: Date.new!(today.year + 1, 1, 7)
  end
end
