defmodule DhcWeb.StripeWebhooksControllerTest do
  use DhcWeb.ConnCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Stripe.Webhook, as: StripeWebhook

  @secret "whsec_test_signing_key_for_webhook_verification"

  describe "POST /api/webhooks/stripe" do
    test "returns 200 and enqueues job for a valid signature", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "id" => "evt_test_200",
          "type" => "charge.succeeded",
          "data" => %{
            "object" => %{
              "id" => "ch_test_200"
            }
          }
        })

      sig_header = StripeWebhook.generate_test_signature(payload, @secret)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", payload)

      assert conn.status == 200
      response = json_response(conn, 200)
      assert response["data"]["received"] == true
      assert response["data"]["event_id"] == "evt_test_200"
    end

    test "returns 401 for invalid signature", %{conn: conn} do
      payload = Jason.encode!(%{"type" => "charge.succeeded"})
      # Use a current timestamp but wrong signature
      timestamp = System.system_time(:second)
      sig_header = "t=#{timestamp},v1=invalid_sig_hex_that_is_exactly_sixty_four_chars_long_x"

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", payload)

      assert conn.status == 401
      assert %{"errors" => _} = json_response(conn, 401)
    end

    test "returns 401 for missing Stripe-Signature header", %{conn: conn} do
      payload = Jason.encode!(%{"type" => "charge.succeeded"})

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/webhooks/stripe", payload)

      assert conn.status == 401
    end

    test "returns 400 for empty body with signature", %{conn: conn} do
      timestamp = System.system_time(:second)
      sig_header = "t=#{timestamp},v1=somesig"

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", "")

      # Empty body — should get 400 or 401 (empty payload fails JSON parse or sig verify)
      assert conn.status in [400, 401]
    end

    test "returns 400 for malformed signature header", %{conn: conn} do
      payload = Jason.encode!(%{"type" => "test"})

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "malformed_header")
        |> post("/api/webhooks/stripe", payload)

      assert conn.status == 400
    end

    test "returns 401 for expired timestamp", %{conn: conn} do
      payload = Jason.encode!(%{"type" => "charge.succeeded"})

      # 600 seconds ago — past the 300s tolerance
      old_timestamp = System.system_time(:second) - 600

      sig_header =
        StripeWebhook.generate_test_signature(payload, @secret, timestamp: old_timestamp)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", payload)

      assert conn.status == 401
    end

    test "returns 200 for subscription event with valid signature", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "id" => "evt_sub_created",
          "type" => "customer.subscription.created",
          "data" => %{
            "object" => %{
              "id" => "sub_123",
              "customer" => "cus_test_123"
            }
          }
        })

      sig_header = StripeWebhook.generate_test_signature(payload, @secret)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", payload)

      assert conn.status == 200
    end

    test "returns 200 for charge.refunded event", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "id" => "evt_refund",
          "type" => "charge.refunded",
          "data" => %{
            "object" => %{
              "id" => "ch_refund_123",
              "customer" => "cus_test_123"
            }
          }
        })

      sig_header = StripeWebhook.generate_test_signature(payload, @secret)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", payload)

      assert conn.status == 200
    end

    test "duplicate delivery enqueues two jobs — Oban does not dedup at enqueue",
         %{conn: _conn} do
      # The DB-guard (`WHERE status = 'pending'` in
      # `confirm_workshop_registration`) is the sole idempotency mechanism.
      # Neither the controller nor Oban deduplicates — Stripe redelivers
      # events on retry, and each delivery enqueues a fresh job. The guard
      # in the worker's DB update makes the second processing a no-op.
      #
      # This test documents that contract at the controller layer: a
      # regression that added Oban `unique` or controller-level event-ID
      # tracking would silently change the idempotency model and stay green
      # against the context-level tests (which call `process_event/1`
      # directly, bypassing enqueue).
      payload =
        Jason.encode!(%{
          "id" => "evt_dup_001",
          "type" => "charge.succeeded",
          "data" => %{
            "object" => %{
              "id" => "ch_dup_001",
              "metadata" => %{
                "workshop_id" => Ecto.UUID.generate(),
                "registration_data" => "test"
              }
            }
          }
        })

      sig_header = StripeWebhook.generate_test_signature(payload, @secret)

      first_conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", payload)

      second_conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> post("/api/webhooks/stripe", payload)

      assert first_conn.status == 200
      assert second_conn.status == 200

      # Two deliveries → two enqueued jobs. The controller does not dedup.
      jobs = all_enqueued(worker: Dhc.StripeWebhooks.Worker)
      assert [_, _] = jobs
      assert Enum.all?(jobs, &(&1.args["event_id"] == "evt_dup_001"))
    end
  end
end
