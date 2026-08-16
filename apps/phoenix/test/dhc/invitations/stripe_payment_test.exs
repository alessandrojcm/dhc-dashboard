defmodule Dhc.Invitations.StripePaymentTest do
  use ExUnit.Case, async: false

  alias Dhc.Invitations.StripePayment

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

  test "reuses the customer identified by acceptance-attempt metadata", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/v1/customers", fn conn ->
      assert conn.query_params["email"] == "member@example.com"
      assert conn.query_params["limit"] == "100"

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

  test "creates a customer with stable attempt metadata when no match exists", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/v1/customers", fn conn ->
      stripe_json(conn, %{"object" => "list", "has_more" => false, "data" => []})
    end)

    Bypass.expect_once(bypass, "POST", "/v1/customers", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

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

  test "continues creating subscriptions when the monthly SEPA payment is processing", %{
    bypass: bypass
  } do
    test_process = self()

    Bypass.stub(bypass, "POST", "/v1/subscriptions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)

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

    Bypass.expect_once(bypass, "GET", "/v1/payment_intents/pi_monthly", fn conn ->
      stripe_json(conn, %{"id" => "pi_monthly", "status" => "processing"})
    end)

    plan = %{
      monthly_price_id: "price_monthly",
      annual_price_id: "price_annual",
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

  defp stripe_json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
