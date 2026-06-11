defmodule DhcWeb.CacheBodyReader do
  @moduledoc """
  A custom body reader that caches the raw request body in `conn.assigns.raw_body`.

  Required for Stripe webhook signature verification, which needs the
  exact bytes Stripe sent. `Plug.Parsers` decodes the body (e.g. JSON),
  but re-encoding it would change whitespace and ordering, breaking the
  HMAC-SHA256 signature check.

  ## How it works

  1. On the first call to `read_body/2`, reads the body and stores it
     in `conn.assigns[:raw_body]` before passing it to the parser.
  2. Subsequent reads return the cached body (Plug.Parsers may read
     the body multiple times).

  ## Configuration

  In your endpoint (`lib/dhc_web/endpoint.ex`):

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library(),
        body_reader: {DhcWeb.CacheBodyReader, :read_body, []}

  Then in your controller, access the raw body via:

      payload = conn.assigns[:raw_body]
  """

  @doc """
  Reads the request body and caches it in `conn.assigns[:raw_body]`.

  Called by `Plug.Parsers` as the body reader. On the first invocation,
  it reads the full body, stores it, and returns it. On subsequent
  invocations (if any), it returns the cached body.
  """
  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()}
  def read_body(conn, opts) do
    case conn.assigns[:raw_body] do
      nil ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
        {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}

      cached ->
        {:ok, cached, conn}
    end
  end
end
