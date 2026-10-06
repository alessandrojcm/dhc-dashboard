defmodule Dhc.Stripe.ClientTest do
  @moduledoc """
  Query encoding of `Dhc.Stripe.Client.request/1` (ALE-342). The client
  builds the query string itself because Req's `:params` keeps only the last
  value of a repeated key.
  """

  use ExUnit.Case, async: true

  alias Dhc.Stripe.Client
  alias Dhc.StripeHTTPStub

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
