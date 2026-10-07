defmodule DhcWeb.CacheBodyReaderTest do
  use DhcWeb.ConnCase, async: true

  alias DhcWeb.CacheBodyReader

  @body ~s({"hello": "world"})

  defp raw_conn(path, body) do
    Plug.Test.conn(:post, path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  test "caches the raw body for the Stripe webhook path" do
    assert {:ok, @body, conn} =
             CacheBodyReader.read_body(raw_conn("/api/webhooks/stripe", @body), [])

    assert conn.assigns.raw_body == @body
    assert {:ok, @body, ^conn} = CacheBodyReader.read_body(conn, [])
  end

  test "does not keep a copy of the body for any other path" do
    assert {:ok, @body, conn} =
             CacheBodyReader.read_body(raw_conn("/api/waitlist/entries", @body), [])

    refute Map.has_key?(conn.assigns, :raw_body)
  end

  test "passes a partial read through unchanged instead of crashing" do
    assert {:more, _partial, conn} =
             CacheBodyReader.read_body(raw_conn("/api/webhooks/stripe", @body), length: 4)

    refute Map.has_key?(conn.assigns, :raw_body)

    assert {:more, _partial, _conn} =
             CacheBodyReader.read_body(raw_conn("/api/waitlist/entries", @body), length: 4)
  end

  test "an oversized JSON body is a 413, not a 500", %{conn: conn} do
    # Plug.Parsers' default length is 8_000_000 bytes.
    body = ~s({"padding": ") <> String.duplicate("a", 8_100_000) <> ~s("})

    for path <- ["/api/waitlist/entries", "/api/webhooks/stripe"] do
      assert_error_sent 413, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post(path, body)
      end
    end
  end
end
