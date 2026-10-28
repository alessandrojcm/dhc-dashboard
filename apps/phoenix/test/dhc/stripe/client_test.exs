defmodule Dhc.Stripe.ClientTest do
  @moduledoc """
  Query encoding of `Dhc.Stripe.Client.request/1` (ALE-342). The client
  builds the query string itself because Req's `:params` keeps only the last
  value of a repeated key.
  """

  use ExUnit.Case, async: true

  alias Dhc.Stripe.Client
  alias Dhc.StripeHTTPStub

  for state <- ~w(complete expired) do
    test "expiring an already #{state} checkout is not an error report" do
      state = unquote(state)
      request_id = "req_closed_#{state}"

      StripeHTTPStub.expect("POST", "/v1/checkout/sessions/cs_private/expire", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("request-id", request_id)
        |> StripeHTTPStub.stripe_error(400, %{
          "message" =>
            ~s(Only Checkout Sessions with a status in ["open"] can be expired. This Checkout Session has a status of `#{state}`.)
        })
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert {:error, {:stripe_api, 400, _}} =
                   Client.request(
                     method: :post,
                     url: "/v1/checkout/sessions/cs_private/expire",
                     body: %{}
                   )
        end)

      refute log =~ request_id
    end
  end

  test "unexpected checkout expiry refusals remain errors without exposing their body" do
    StripeHTTPStub.expect("POST", "/v1/checkout/sessions/cs_private/expire", fn conn ->
      StripeHTTPStub.stripe_error(conn, 400, %{
        "message" => "Unexpected refusal private@example.test",
        "code" => "parameter_unknown"
      })
    end)

    log =
      ExUnit.CaptureLog.capture_log([level: :error], fn ->
        assert {:error, {:stripe_api, 400, _}} =
                 Client.request(
                   method: :post,
                   url: "/v1/checkout/sessions/cs_private/expire",
                   body: %{}
                 )
      end)

    assert log =~ "parameter_unknown"
    refute log =~ "private"
  end

  test "failure logs contain safe diagnostics, never Stripe response bodies or resource ids" do
    StripeHTTPStub.expect("POST", "/v1/customers/cus_private/subscriptions", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("request-id", "req_test123")
      |> StripeHTTPStub.json(400, %{
        "error" => %{
          "type" => "invalid_request_error",
          "code" => "parameter_invalid_integer",
          "message" => "private@example.test secret-body",
          "param" => "quantity"
        }
      })
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:stripe_api, 400, _}} =
                 Client.request(
                   method: :post,
                   url: "/v1/customers/cus_private/subscriptions",
                   body: %{}
                 )
      end)

    refute log =~ "private"
    refute log =~ "secret-body"
    assert log =~ "parameter_invalid_integer"
    assert log =~ "req_test123"
    assert log =~ "/v1/customers/:id/subscriptions"
  end

  defp sent_query(query) do
    test_pid = self()

    StripeHTTPStub.expect("GET", "/v1/things", fn conn ->
      send(test_pid, {:query_string, conn.query_string})
      StripeHTTPStub.json(conn, %{})
    end)

    assert {:ok, %{}} = Client.request(method: :get, url: "/v1/things", query: query)
    assert_received {:query_string, query_string}
    query_string |> URI.query_decoder() |> Enum.to_list()
  end

  test "repeats a list value as key[] pairs, keeping every value" do
    assert sent_query(lookup_keys: ["a", "b"], limit: 10) == [
             {"lookup_keys[]", "a"},
             {"lookup_keys[]", "b"},
             {"limit", "10"}
           ]
  end

  test "does not double [] on a key that already ends in []" do
    assert sent_query([{"expand[]", ["data.latest_invoice"]}, {"status[]", "all"}]) == [
             {"expand[]", "data.latest_invoice"},
             {"status[]", "all"}
           ]
  end

  test "skips nil values instead of sending key=" do
    assert sent_query(customer: nil, limit: 1, expand: [nil, "x"]) == [
             {"limit", "1"},
             {"expand[]", "x"}
           ]
  end

  test "sends no query string for an empty or all-nil query" do
    assert sent_query([]) == []
    assert sent_query(starting_after: nil) == []
  end

  test "rejects a map value with a clear error" do
    assert_raise ArgumentError, ~r/nested map.*created/, fn ->
      Client.request(method: :get, url: "/v1/things", query: [created: %{gte: 1}])
    end
  end
end
