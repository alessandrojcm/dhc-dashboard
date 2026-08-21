defmodule DhcWeb.MembershipControllerTest do
  use DhcWeb.ConnCase, async: false

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

  defp expect_saved_sepa_method(bypass, customer_id, payment_method_id) do
    Bypass.expect(bypass, "GET", "/v1/customers/#{customer_id}/payment_methods", fn conn ->
      assert conn.query_params["type"] == "sepa_debit"

      stripe_json(conn, %{
        "object" => "list",
        "data" => [
          %{
            "id" => payment_method_id,
            "type" => "sepa_debit",
            "sepa_debit" => %{"bank_code" => "37040044", "country" => "DE"}
          }
        ],
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
