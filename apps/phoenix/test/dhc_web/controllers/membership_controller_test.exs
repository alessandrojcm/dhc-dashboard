defmodule DhcWeb.MembershipControllerTest do
  use DhcWeb.ConnCase, async: false

  import Ecto.Query

  # Only these roles may mint new membership charges (ALE-251 review
  # decision). Deliberately narrower than the members-admin read list —
  # coordinators without billing authority must be rejected.
  @membership_minting_roles ~w(admin president treasurer committee_coordinator)

  # Authenticated committee roles that must NOT mint charges.
  @non_minting_committee_roles ~w(sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)

  defmodule Verifier do
    def verify("member-token") do
      # No roles: proves reactivation is committee-only — unlike pause/resume
      # there is no self-service fallback, because the command mints charges.
      ok([], "member@example.com")
    end

    def verify(token) do
      case Regex.run(~r/\A([a-z_]+)-token\z/, token) do
        [_, role] -> ok([role], "committee@example.com")
        _ -> {:error, :invalid_token}
      end
    end

    defp ok(roles, email) do
      {:ok,
       %{
         sub: Ecto.UUID.generate(),
         email: email,
         roles: roles,
         raw: %{}
       }}
    end
  end

  setup do
    original_verifier = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original_verifier) end)
  end

  describe "reactivate authorization" do
    test "returns 403 for a caller without a committee role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> post("/api/members/11111111-1111-1111-1111-111111111111/membership/reactivate", %{
          "startDate" => Date.to_iso8601(Date.utc_today())
        })

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 401 without a session", %{conn: conn} do
      conn =
        post(conn, "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivate", %{
          "startDate" => Date.to_iso8601(Date.utc_today())
        })

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 404 when the member does not exist", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/11111111-1111-1111-1111-111111111111/membership/reactivate", %{
          "startDate" => Date.to_iso8601(Date.utc_today())
        })

      assert %{"errors" => %{"detail" => "Member not found"}} = json_response(conn, 404)
    end

    test "lets every membership-minting role past the pipeline", %{conn: conn} do
      Enum.each(@membership_minting_roles, fn role ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> post("/api/members/11111111-1111-1111-1111-111111111111/membership/reactivate", %{
            "startDate" => Date.to_iso8601(Date.utc_today())
          })

        # No member fixture → the request must reach the controller (404).
        # A pipeline rejection would surface as 403 instead.
        response = json_response(conn, 404)

        assert %{"errors" => %{"detail" => "Member not found"}} = response,
               "role #{role} should pass the minting pipeline"
      end)
    end

    test "returns 403 for committee roles without minting authority", %{conn: conn} do
      Enum.each(@non_minting_committee_roles, fn role ->
        conn =
          conn
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> post("/api/members/11111111-1111-1111-1111-111111111111/membership/reactivate", %{
            "startDate" => Date.to_iso8601(Date.utc_today())
          })

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403),
               "role #{role} must not mint membership charges"
      end)
    end
  end

  describe "reactivate membership-state guards" do
    setup :stripe_bypass

    test "returns 409 when the member already has an active membership", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: true, customer_id: "cus_active")

      expect_subscription_list(bypass, "cus_active", [active_membership_subscription()])

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => Date.to_iso8601(Date.utc_today())
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 409)
      assert detail =~ "active"
    end

    test "returns 409 when the member has a paused membership", %{conn: conn, bypass: bypass} do
      member =
        insert_member(
          is_active: true,
          customer_id: "cus_paused",
          subscription_paused_until: DateTime.utc_now() |> DateTime.add(30, :day)
        )

      expect_subscription_list(bypass, "cus_paused", [paused_membership_subscription()])

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => Date.to_iso8601(Date.utc_today())
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 409)
      assert detail =~ "paused"
    end

    test "returns 409 based on Stripe coverage even when the local flag lags", %{
      conn: conn,
      bypass: bypass
    } do
      # is_active is a sync projection (ADR-0008): an inactive-flagged member
      # whose Stripe customer still holds a live subscription must not be
      # reactivated into a second set of subscriptions.
      member = insert_member(is_active: false, customer_id: "cus_drift")

      expect_subscription_list(bypass, "cus_drift", [active_membership_subscription()])

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => Date.to_iso8601(Date.utc_today())
        })

      assert %{"errors" => %{"detail" => _}} = json_response(conn, 409)
    end
  end

  describe "reactivate startDate validation" do
    test "returns 422 for a non-date startDate", %{conn: conn} do
      member = insert_member(is_active: false, customer_id: "cus_bad_date")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => "not-a-date"
        })

      assert %{"errors" => %{"detail" => "Invalid membership reactivation payload"}} =
               json_response(conn, 422)
    end

    test "returns 422 for a past startDate", %{conn: conn} do
      member = insert_member(is_active: false, customer_id: "cus_past_date")

      past = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{
          "startDate" => past
        })

      assert %{"errors" => %{"detail" => "Invalid membership reactivation payload"}} =
               json_response(conn, 422)
    end

    test "returns 422 when startDate is missing", %{conn: conn} do
      member = insert_member(is_active: false, customer_id: "cus_missing_date")

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> post("/api/members/#{member.auth_user_id}/membership/reactivate", %{})

      assert %{"errors" => %{"detail" => "Invalid membership reactivation payload"}} =
               json_response(conn, 422)
    end
  end

  describe "reactivate without a saved payment method" do
    setup :stripe_bypass

    test "returns 409 with the no_saved_payment_method code", %{conn: conn, bypass: bypass} do
      member = insert_member(is_active: false, customer_id: "cus_no_pm")

      expect_subscription_list(bypass, "cus_no_pm", [])

      Bypass.expect_once(bypass, "GET", "/v1/customers/cus_no_pm/payment_methods", fn conn ->
        assert conn.query_params["type"] == "sepa_debit"

        stripe_json(conn, %{"object" => "list", "data" => [], "has_more" => false})
      end)

      conn = post_reactivate(conn, member.auth_user_id, Date.utc_today())

      assert %{"errors" => %{"detail" => detail, "code" => "no_saved_payment_method"}} =
               json_response(conn, 409)

      assert detail =~ "billing portal"
    end
  end

  describe "reactivate happy path" do
    setup :stripe_bypass

    test "creates both subscriptions against the saved SEPA method and confirms off-session", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: false, customer_id: "cus_happy")
      start_date = Date.utc_today() |> Date.add(7)
      expected_anchor = Integer.to_string(midnight_unix(start_date))
      prefix = idempotency_prefix(member.auth_user_id, start_date)

      expect_reactivation_choreography(bypass, %{
        customer_id: "cus_happy",
        payment_method_id: "pm_sepa_saved",
        monthly_price_id: "price_monthly",
        annual_price_id: "price_annual",
        monthly_subscription_id: "sub_monthly",
        annual_subscription_id: "sub_annual",
        payment_intent_status: "succeeded",
        idempotency_prefix: prefix,
        billing_cycle_anchor: expected_anchor
      })

      conn = post_reactivate(conn, member.auth_user_id, start_date)

      assert %{
               "data" => %{
                 "memberId" => returned_member_id,
                 "paymentState" => "succeeded",
                 "monthlySubscriptionId" => "sub_monthly",
                 "annualSubscriptionId" => "sub_annual"
               }
             } = json_response(conn, 200)

      assert returned_member_id == member.auth_user_id

      # Success restores dashboard access immediately (ALE-252): the daily
      # sync would eventually catch up, but the operator must see the member
      # as active right away.
      assert_member_active("cus_happy")
    end

    test "confirms the first invoice WITHOUT mandate_data (mandate is reused)", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: false, customer_id: "cus_nomandate")
      start_date = Date.utc_today() |> Date.add(7)

      expect_reactivation_choreography(bypass, %{
        customer_id: "cus_nomandate",
        payment_method_id: "pm_sepa_saved",
        monthly_price_id: "price_monthly",
        annual_price_id: "price_annual",
        monthly_subscription_id: "sub_monthly",
        annual_subscription_id: "sub_annual",
        payment_intent_status: "succeeded",
        idempotency_prefix: idempotency_prefix(member.auth_user_id, start_date),
        billing_cycle_anchor: Integer.to_string(midnight_unix(start_date)),
        assert_confirm_body: fn body ->
          # The saved method is charged under the member's EXISTING mandate:
          # acceptance is recorded as offline (operator-initiated), never a
          # fresh online collection from the member.
          assert body == %{
                   "payment_method" => "pm_sepa_saved",
                   "mandate_data[customer_acceptance][type]" => "offline"
                 }
        end
      })

      conn = post_reactivate(conn, member.auth_user_id, start_date)

      assert %{"data" => %{"paymentState" => "succeeded"}} = json_response(conn, 200)
    end
  end

  describe "reactivate pending settlement" do
    setup :stripe_bypass

    test "surfaces async SEPA processing as a pending outcome", %{conn: conn, bypass: bypass} do
      member = insert_member(is_active: false, customer_id: "cus_pending")
      start_date = Date.utc_today() |> Date.add(7)

      expect_reactivation_choreography(bypass, %{
        customer_id: "cus_pending",
        payment_method_id: "pm_sepa_saved",
        monthly_price_id: "price_monthly",
        annual_price_id: "price_annual",
        monthly_subscription_id: "sub_monthly_pending",
        annual_subscription_id: "sub_annual_pending",
        payment_intent_status: "processing",
        idempotency_prefix: idempotency_prefix(member.auth_user_id, start_date),
        billing_cycle_anchor: Integer.to_string(midnight_unix(start_date))
      })

      conn = post_reactivate(conn, member.auth_user_id, start_date)

      assert %{
               "data" => %{
                 "paymentState" => "pending",
                 "monthlySubscriptionId" => "sub_monthly_pending",
                 "annualSubscriptionId" => "sub_annual_pending"
               }
             } = json_response(conn, 200)

      # Async SEPA settlement is still a healthy reactivation: subscriptions
      # exist and cover the member while the bank processes the debit.
      assert_member_active("cus_pending")
    end
  end

  describe "reactivate idempotency keys" do
    setup :stripe_bypass

    test "derive from member id and start date and are stable across retries", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: false, customer_id: "cus_idem")
      start_date = Date.utc_today() |> Date.add(7)
      prefix = idempotency_prefix(member.auth_user_id, start_date)

      observed_keys = :ets.new(:observed_keys, [:bag, :public])

      expect_reactivation_choreography(bypass, %{
        customer_id: "cus_idem",
        payment_method_id: "pm_sepa_saved",
        monthly_price_id: "price_monthly",
        annual_price_id: "price_annual",
        monthly_subscription_id: "sub_monthly",
        annual_subscription_id: "sub_annual",
        payment_intent_status: "succeeded",
        idempotency_prefix: prefix,
        billing_cycle_anchor: Integer.to_string(midnight_unix(start_date)),
        observe_keys: observed_keys
      })

      # Two identical requests — the same deterministic key namespace must be
      # replayed so Stripe dedupes instead of double-charging.
      conn1 = post_reactivate(conn, member.auth_user_id, start_date)
      assert %{"data" => %{"paymentState" => "succeeded"}} = json_response(conn1, 200)

      conn2 = post_rebuild_conn(conn, member.auth_user_id, start_date)
      assert %{"data" => %{"paymentState" => "succeeded"}} = json_response(conn2, 200)

      keys = observed_keys |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert "membership-reactivate:#{member.auth_user_id}:#{Date.to_iso8601(start_date)}:subscription-monthly" in keys

      assert "membership-reactivate:#{member.auth_user_id}:#{Date.to_iso8601(start_date)}:subscription-annual" in keys

      assert Enum.any?(
               keys,
               &String.starts_with?(&1, "#{prefix}:payment-intent-pi_")
             )

      # Every mutating call used the SAME namespace — no invitation-era keys.
      refute Enum.any?(keys, &String.contains?(&1, "invitation-acceptance"))
    end
  end

  describe "reactivate stripe failure" do
    setup :stripe_bypass

    test "returns 502 when subscription creation fails", %{conn: conn, bypass: bypass} do
      member = insert_member(is_active: false, customer_id: "cus_fail")
      start_date = Date.utc_today() |> Date.add(7)

      expect_subscription_list(bypass, "cus_fail", [])

      expect_saved_sepa_method(bypass, "cus_fail", "pm_sepa_saved")

      expect_membership_prices(bypass, "price_monthly", "price_annual")

      Bypass.expect_once(bypass, "POST", "/v1/subscriptions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
      end)

      conn = post_reactivate(conn, member.auth_user_id, start_date)

      assert %{"errors" => %{"detail" => "Stripe membership reactivation failed"}} =
               json_response(conn, 502)
    end
  end

  describe "reactivation preview authorization" do
    test "returns 403 for a caller without a committee role", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer member-token")
        |> get(
          "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview"
        )

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 401 without a session", %{conn: conn} do
      conn =
        get(
          conn,
          "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview"
        )

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 404 when the member does not exist", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(
          "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview"
        )

      assert %{"errors" => %{"detail" => "Member not found"}} = json_response(conn, 404)
    end

    test "lets every membership-minting role past the pipeline", %{conn: conn} do
      Enum.each(@membership_minting_roles, fn role ->
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get(
            "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview"
          )

        # No member fixture → the request must reach the controller (404).
        # A pipeline rejection would surface as 403 instead.
        response = json_response(conn, 404)

        assert %{"errors" => %{"detail" => "Member not found"}} = response,
               "role #{role} should pass the minting pipeline"
      end)
    end

    test "returns 403 for committee roles without minting authority", %{conn: conn} do
      Enum.each(@non_minting_committee_roles, fn role ->
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{role}-token")
          |> get(
            "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview"
          )

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403),
               "role #{role} must not read saved payment data"
      end)
    end
  end

  describe "reactivation preview" do
    setup :stripe_bypass

    test "summarises the saved SEPA method a reactivation would charge", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: false, customer_id: "cus_preview")

      expect_saved_sepa_method(bypass, "cus_preview", "pm_sepa_preview", %{
        "last4" => "1234",
        "bank_code" => "37040044",
        "country" => "DE"
      })

      conn =
        conn
        |> put_req_header("authorization", "Bearer treasurer-token")
        |> get("/api/members/#{member.auth_user_id}/membership/reactivation-preview")

      assert %{
               "data" => %{
                 "memberId" => returned_member_id,
                 "savedPaymentMethod" => %{
                   "id" => "pm_sepa_preview",
                   "last4" => "1234",
                   "bankCode" => "37040044",
                   "country" => "DE"
                 }
               }
             } = json_response(conn, 200)

      assert returned_member_id == member.auth_user_id
    end

    test "returns a null savedPaymentMethod when no usable method exists", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: false, customer_id: "cus_preview_empty")

      expect_saved_sepa_methods(bypass, "cus_preview_empty", [])

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members/#{member.auth_user_id}/membership/reactivation-preview")

      assert %{
               "data" => %{
                 "memberId" => returned_member_id,
                 "savedPaymentMethod" => nil
               }
             } = json_response(conn, 200)

      assert returned_member_id == member.auth_user_id
    end

    test "returns 502 when the Stripe lookup fails", %{conn: conn, bypass: bypass} do
      member = insert_member(is_active: false, customer_id: "cus_preview_fail")

      Bypass.expect_once(
        bypass,
        "GET",
        "/v1/customers/cus_preview_fail/payment_methods",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
        end
      )

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get("/api/members/#{member.auth_user_id}/membership/reactivation-preview")

      assert %{"errors" => %{"detail" => "Stripe payment-method lookup failed"}} =
               json_response(conn, 502)
    end
  end

  # ALE-254: Stripe-computed amounts behind the operator modal's
  # pre-confirmation preview.
  describe "reactivation amounts preview" do
    setup :stripe_bypass

    @monthly_initial_amount 1500
    @monthly_recurring_amount 4200
    @annual_initial_amount 31500
    @annual_recurring_amount 36000

    test "keeps the minting pipeline in front of the amounts read", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer coach-token")
        |> get(
          "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview/amounts?startDate=#{Date.to_iso8601(Date.utc_today())}"
        )

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 401 without a session", %{conn: conn} do
      conn =
        get(
          conn,
          "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview/amounts?startDate=#{Date.to_iso8601(Date.utc_today())}"
        )

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns Stripe-computed amounts for a start date of today", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: false, customer_id: "cus_amounts")

      opts = amounts_opts("price_monthly", "price_annual", Date.utc_today())

      expect_amounts_previews(bypass, opts)

      conn =
        conn
        |> put_req_header("authorization", "Bearer treasurer-token")
        |> get(
          "/api/members/#{member.auth_user_id}/membership/reactivation-preview/amounts",
          startDate: Date.to_iso8601(Date.utc_today())
        )

      expected_due_today = @monthly_initial_amount + @annual_initial_amount

      assert %{
               "data" => %{
                 "dueToday" => %{"amount" => due_today, "currency" => "EUR", "precision" => 2},
                 "monthlyFee" => %{
                   "amount" => @monthly_recurring_amount,
                   "currency" => "EUR",
                   "precision" => 2
                 },
                 "annualFee" => %{
                   "amount" => @annual_recurring_amount,
                   "currency" => "EUR",
                   "precision" => 2
                 }
               }
             } = json_response(conn, 200)

      assert due_today == expected_due_today
    end

    test "anchors the monthly first-invoice preview at a future start date", %{
      conn: conn,
      bypass: bypass
    } do
      member = insert_member(is_active: false, customer_id: "cus_amounts_future")
      start_date = Date.add(Date.utc_today(), 10)

      opts = amounts_opts("price_monthly_f", "price_annual_f", start_date)

      expect_amounts_previews(bypass, opts)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(
          "/api/members/#{member.auth_user_id}/membership/reactivation-preview/amounts",
          startDate: Date.to_iso8601(start_date)
        )

      assert %{"data" => %{"dueToday" => %{"amount" => due_today}}} = json_response(conn, 200)

      assert due_today == @monthly_initial_amount + @annual_initial_amount
    end

    test "does not look up payment methods or subscriptions", %{conn: conn, bypass: bypass} do
      member = insert_member(is_active: false, customer_id: "cus_amounts_only")
      opts = amounts_opts("price_monthly_o", "price_annual_o", Date.utc_today())

      expect_amounts_previews(bypass, opts)

      # Any other Stripe call (payment methods, subscription guard) would hit
      # Bypass and find no route → the request would fail with a raised error
      # rather than silently passing.
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(
          "/api/members/#{member.auth_user_id}/membership/reactivation-preview/amounts",
          startDate: Date.to_iso8601(Date.utc_today())
        )

      assert %{"data" => %{}} = json_response(conn, 200)
    end

    test "returns 422 when startDate is missing, malformed, or out of range", %{conn: _conn} do
      member = insert_member(is_active: false, customer_id: "cus_amounts_invalid")

      base = "/api/members/#{member.auth_user_id}/membership/reactivation-preview/amounts"
      headers = [authorization: "Bearer admin-token"]

      past = Date.add(Date.utc_today(), -1)
      too_far = Date.add(Date.utc_today(), 367)

      for {label, query} <- [
            {"missing", []},
            {"malformed", [startDate: "not-a-date"]},
            {"past", [startDate: Date.to_iso8601(past)]},
            {"beyond-max-window", [startDate: Date.to_iso8601(too_far)]}
          ] do
        conn =
          build_conn()
          |> put_req_header("authorization", Keyword.fetch!(headers, :authorization))
          |> get(base, query)

        assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422), label
        assert detail =~ "Invalid membership reactivation", label
      end
    end

    test "returns 404 when the member does not exist", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(
          "/api/members/11111111-1111-1111-1111-111111111111/membership/reactivation-preview/amounts?startDate=#{Date.to_iso8601(Date.utc_today())}"
        )

      assert %{"errors" => %{"detail" => "Member not found"}} = json_response(conn, 404)
    end

    test "returns 502 when a Stripe invoice preview fails", %{conn: conn, bypass: bypass} do
      member = insert_member(is_active: false, customer_id: "cus_amounts_fail")
      opts = amounts_opts("price_monthly_x", "price_annual_x", Date.utc_today())

      expect_membership_prices(bypass, opts.monthly_price_id, opts.annual_price_id)

      Bypass.expect(bypass, "POST", "/v1/invoices/create_preview", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
      end)

      conn =
        conn
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(
          "/api/members/#{member.auth_user_id}/membership/reactivation-preview/amounts",
          startDate: Date.to_iso8601(Date.utc_today())
        )

      assert %{"errors" => %{"detail" => "Stripe membership cost preview failed"}} =
               json_response(conn, 502)
    end

    test "returns 502 (not a crash) when the membership price lookup fails", %{
      conn: _conn,
      bypass: bypass
    } do
      # Regression (spec review): internal price-lookup error tuples used to
      # escape preview_amounts/1 and fall through the controller case as a
      # 500. Every Stripe failure must surface as the graceful 502.
      # Stripe answers 200 but has no active membership prices
      # → internal {:price_not_found, _}.
      Bypass.expect_once(bypass, "GET", "/v1/prices", fn conn ->
        stripe_json(conn, %{"object" => "list", "data" => [], "has_more" => false})
      end)

      member_empty =
        insert_member(is_active: false, customer_id: "cus_amounts_no_prices")

      empty_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(
          "/api/members/#{member_empty.auth_user_id}/membership/reactivation-preview/amounts",
          startDate: Date.to_iso8601(Date.utc_today())
        )

      assert %{"errors" => %{"detail" => "Stripe membership cost preview failed"}} =
               json_response(empty_conn, 502)

      # Stripe answers 500 → internal {:stripe, _}.
      Bypass.expect_once(bypass, "GET", "/v1/prices", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "boom"}}))
      end)

      member_500 =
        insert_member(is_active: false, customer_id: "cus_amounts_prices_500")

      failing_prices_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer admin-token")
        |> get(
          "/api/members/#{member_500.auth_user_id}/membership/reactivation-preview/amounts",
          startDate: Date.to_iso8601(Date.utc_today())
        )

      assert %{"errors" => %{"detail" => "Stripe membership cost preview failed"}} =
               json_response(failing_prices_conn, 502)
    end
  end

  defp insert_member(attrs \\ []) do
    today = Date.utc_today()
    date_of_birth = %{today | year: today.year - Keyword.get(attrs, :age, 20)}

    Dhc.MemberFixtures.member_fixture(
      gender: Keyword.get(attrs, :gender, "man (cis)"),
      date_of_birth: date_of_birth,
      preferred_weapon: Keyword.get(attrs, :preferred_weapon, ["longsword"]),
      is_active: Keyword.get(attrs, :is_active, true),
      first_name: Keyword.get(attrs, :first_name, "Test"),
      last_name: Keyword.get(attrs, :last_name, "Member"),
      subscription_paused_until: Keyword.get(attrs, :subscription_paused_until),
      auth_user_id: Keyword.get(attrs, :auth_user_id),
      email: Keyword.get(attrs, :email),
      phone_number: Keyword.get(attrs, :phone_number),
      customer_id: Keyword.get(attrs, :customer_id)
    )
  end

  defp assert_member_active(customer_id) do
    profile =
      Dhc.Repo.one!(
        from up in Dhc.UserProfiles.UserProfile,
          where: up.customer_id == ^customer_id,
          select: %{id: up.id, is_active: up.is_active}
      )

    assert profile.is_active, "reactivation must restore member access"
  end

  defp stripe_bypass(_context) do
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

  defp post_reactivate(conn, member_id, start_date \\ nil) do
    payload =
      case start_date do
        nil -> %{}
        date -> %{"startDate" => Date.to_iso8601(date)}
      end

    conn
    |> put_req_header("authorization", "Bearer admin-token")
    |> post("/api/members/#{member_id}/membership/reactivate", payload)
  end

  # A second request must be built on a fresh conn.
  defp post_rebuild_conn(_conn, member_id, start_date) do
    build_conn()
    |> put_req_header("authorization", "Bearer admin-token")
    |> post("/api/members/#{member_id}/membership/reactivate", %{
      "startDate" => Date.to_iso8601(start_date)
    })
  end

  defp midnight_unix(date) do
    date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
  end

  defp idempotency_prefix(member_id, start_date) do
    "membership-reactivate:#{member_id}:#{Date.to_iso8601(start_date)}"
  end

  defp expect_saved_sepa_method(bypass, customer_id, payment_method_id, sepa_debit \\ nil) do
    expect_saved_sepa_methods(bypass, customer_id, [
      %{
        "id" => payment_method_id,
        "type" => "sepa_debit",
        # Real Stripe omits last4 unless the method was used at least once;
        # the reactivation fixtures keep the minimal legacy shape.
        "sepa_debit" => sepa_debit || %{"bank_code" => "37040044", "country" => "DE"}
      }
    ])
  end

  defp expect_saved_sepa_methods(bypass, customer_id, methods) do
    Bypass.expect(bypass, "GET", "/v1/customers/#{customer_id}/payment_methods", fn conn ->
      assert conn.query_params["type"] == "sepa_debit"

      stripe_json(conn, %{
        "object" => "list",
        "data" => methods,
        "has_more" => false
      })
    end)
  end

  defp expect_membership_prices(bypass, monthly_price_id, annual_price_id) do
    lookup_to_price = %{
      "standard_membership_fee" => monthly_price_id,
      "annual_membership_fee_revised" => annual_price_id
    }

    Bypass.expect(bypass, "GET", "/v1/prices", fn conn ->
      # Plug decodes `lookup_keys[]=` into a list under "lookup_keys".
      assert [lookup_key] = conn.query_params["lookup_keys"]
      price_id = Map.fetch!(lookup_to_price, lookup_key)

      stripe_json(conn, %{
        "object" => "list",
        "data" => [%{"id" => price_id, "lookup_key" => lookup_key}],
        "has_more" => false
      })
    end)
  end

  # Stubs the full reactivation choreography against Stripe:
  #
  #   GET /v1/subscriptions          → no live memberships (guard passes)
  #   GET .../payment_methods        → one saved SEPA method
  #   GET /v1/prices                 → monthly + annual lookup-key prices
  #   POST /v1/subscriptions         → monthly then annual (branching on the
  #                                    billing_cycle_anchor form param)
  #   POST .../payment_intents/:id/confirm → scripted PI status
  #
  # Every mutating call's Idempotency-Key header is asserted to carry the
  # deterministic `membership-reactivate:<member>:<date>` namespace.
  defp expect_reactivation_choreography(bypass, opts) do
    expect_subscription_list(bypass, opts.customer_id, [])
    expect_saved_sepa_method(bypass, opts.customer_id, opts.payment_method_id)
    expect_membership_prices(bypass, opts.monthly_price_id, opts.annual_price_id)

    observe_keys = Map.get(opts, :observe_keys)
    assert_confirm_body = Map.get(opts, :assert_confirm_body)

    record_key = fn conn ->
      case Plug.Conn.get_req_header(conn, "idempotency-key") do
        [key] ->
          if observe_keys, do: :ets.insert(observe_keys, {key})

          assert String.starts_with?(key, "#{opts.idempotency_prefix}:"),
                 "unexpected idempotency key #{inspect(key)}"

        [] ->
          flunk("mutating Stripe call missing Idempotency-Key header")
      end
    end

    Bypass.expect(bypass, "POST", "/v1/subscriptions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      record_key.(conn)

      assert params["customer"] == opts.customer_id
      assert params["payment_behavior"] == "default_incomplete"
      assert params["collection_method"] == "charge_automatically"
      assert params["default_payment_method"] == opts.payment_method_id
      assert params["expand[]"] == "latest_invoice.payments"
      assert params["metadata[purpose]"] == "membership-reactivation"

      {kind, price_id, sub_id} =
        if Map.has_key?(params, "billing_cycle_anchor") do
          assert params["billing_cycle_anchor"] == opts.billing_cycle_anchor
          refute Map.has_key?(params, "billing_cycle_anchor_config[month]")
          {:monthly, opts.monthly_price_id, opts.monthly_subscription_id}
        else
          assert params["billing_cycle_anchor_config[month]"] == "1"
          assert params["billing_cycle_anchor_config[day_of_month]"] == "7"
          {:annual, opts.annual_price_id, opts.annual_subscription_id}
        end

      assert params["items[0][price]"] == price_id
      assert params["metadata[kind]"] == Atom.to_string(kind)

      stripe_json(conn, incomplete_subscription_json(sub_id))
    end)

    Enum.each([opts.monthly_subscription_id, opts.annual_subscription_id], fn sub_id ->
      payment_intent_id = "pi_#{sub_id}"

      # Repeatable: idempotency tests replay identical requests, and Stripe
      # would answer the replayed confirm from its stored idempotent response.
      Bypass.expect(bypass, "POST", "/v1/payment_intents/#{payment_intent_id}/confirm", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        record_key.(conn)

        if assert_confirm_body, do: assert_confirm_body.(params)

        assert params["payment_method"] == opts.payment_method_id

        stripe_json(conn, %{"id" => payment_intent_id, "status" => opts.payment_intent_status})
      end)
    end)
  end

  defp incomplete_subscription_json(subscription_id) do
    %{
      "id" => subscription_id,
      "status" => "incomplete",
      "latest_invoice" => %{
        "id" => "in_#{subscription_id}",
        "status" => "open",
        "amount_due" => 4200,
        "payments" => %{
          "data" => [
            %{"payment" => %{"payment_intent" => "pi_#{subscription_id}"}}
          ]
        }
      }
    }
  end

  defp expect_subscription_list(bypass, customer_id, subscriptions) do
    Bypass.expect(bypass, "GET", "/v1/subscriptions", fn conn ->
      assert conn.query_params["customer"] == customer_id

      stripe_json(conn, %{
        "object" => "list",
        "data" => subscriptions,
        "has_more" => false
      })
    end)
  end

  # Options for `expect_amounts_previews/2`: pins which invoice amount each
  # create_preview branch returns and which anchor parameters the command's
  # preview must mirror (ALE-254).
  defp amounts_opts(monthly_price_id, annual_price_id, start_date) do
    today = Date.utc_today()

    monthly_initial_anchor =
      if Date.compare(start_date, today) == :gt, do: midnight_unix(start_date)

    %{
      monthly_price_id: monthly_price_id,
      annual_price_id: annual_price_id,
      start_date_unix: midnight_unix(start_date),
      monthly_initial_anchor: monthly_initial_anchor,
      invoices: %{
        monthly_initial: @monthly_initial_amount,
        monthly_recurring: @monthly_recurring_amount,
        annual_initial: @annual_initial_amount,
        annual_recurring: @annual_recurring_amount
      }
    }
  end

  # Stubs GET /v1/prices plus the four POST /v1/invoices/create_preview calls
  # a reactivation amounts preview performs, branching on the subscription
  # price and date key:
  #
  #   monthly price + billing_cycle_anchor → prorated first invoice (future start)
  #   monthly price + no date key          → full first invoice (start = today)
  #   monthly price + start_date           → upcoming full monthly period
  #   annual price  + billing_cycle_anchor → prorated annual fee to January
  #   annual price  + start_date           → upcoming full annual period
  defp expect_amounts_previews(bypass, opts) do
    expect_membership_prices(bypass, opts.monthly_price_id, opts.annual_price_id)

    Bypass.expect(bypass, "POST", "/v1/invoices/create_preview", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      anchor_key = "subscription_details[billing_cycle_anchor]"
      start_key = "subscription_details[start_date]"

      assert params["subscription_details[items][0][quantity]"] == "1"
      assert map_size(Map.take(params, [anchor_key, start_key])) in 0..1

      price_id = Map.fetch!(params, "subscription_details[items][0][price]")
      anchored? = Map.has_key?(params, anchor_key)
      start_dated? = Map.has_key?(params, start_key)

      kind =
        cond do
          price_id == opts.monthly_price_id and not anchored? and not start_dated? ->
            :monthly_initial

          price_id == opts.monthly_price_id and anchored? ->
            assert params[anchor_key] == Integer.to_string(opts.monthly_initial_anchor)
            :monthly_initial

          price_id == opts.monthly_price_id ->
            assert params[start_key] == Integer.to_string(opts.start_date_unix)
            :monthly_recurring

          price_id == opts.annual_price_id and anchored? ->
            # The command resolves billing_cycle_anchor_config to next Jan 7 at
            # creation time-of-day UTC; tolerate second-level drift.
            assert abs(String.to_integer(params[anchor_key]) - january_anchor_now_unix()) <= 60
            :annual_initial

          price_id == opts.annual_price_id ->
            assert abs(String.to_integer(params[start_key]) - january_anchor_now_unix()) <= 60
            :annual_recurring

          true ->
            flunk("unexpected create_preview price #{inspect(price_id)}")
        end

      stripe_json(conn, preview_invoice_json(kind, Map.fetch!(opts.invoices, kind)))
    end)
  end

  defp preview_invoice_json(kind, amount) do
    %{
      "id" => "in_preview_#{kind}",
      "object" => "invoice",
      "currency" => "eur",
      "amount_due" => amount,
      "subtotal" => amount
    }
  end

  # Mirrors the documented annual anchor rule: the next January 7 at the
  # current UTC time-of-day (billing_cycle_anchor_config resolution).
  defp january_anchor_now_unix do
    today = Date.utc_today()
    candidate = Date.new!(today.year, 1, 7)

    date =
      if Date.compare(candidate, today) == :gt,
        do: candidate,
        else: Date.new!(today.year + 1, 1, 7)

    now = Time.utc_now()

    DateTime.new!(date, %{now | microsecond: {0, 0}}, "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp active_membership_subscription do
    %{
      "id" => "sub_membership",
      "status" => "active",
      "pause_collection" => nil,
      "items" => %{
        "data" => [
          %{"price" => %{"lookup_key" => "standard_membership_fee"}}
        ]
      }
    }
  end

  defp paused_membership_subscription do
    %{
      "id" => "sub_membership",
      "status" => "active",
      "pause_collection" => %{"behavior" => "void"},
      "items" => %{
        "data" => [
          %{"price" => %{"lookup_key" => "standard_membership_fee"}}
        ]
      }
    }
  end

  defp stripe_json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
