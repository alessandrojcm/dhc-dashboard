defmodule DhcWeb.CacheBodyReader do
  @moduledoc """
  The `Plug.Parsers` body reader. It caches the raw request body in
  `conn.assigns.raw_body` for the Stripe webhook only.

  Stripe webhook signature verification needs the exact bytes Stripe sent.
  `Plug.Parsers` decodes the body (e.g. JSON), but re-encoding it would change
  whitespace and ordering, breaking the HMAC-SHA256 signature check.

  ## How it works

    * For `POST /api/webhooks/stripe`, a complete read (`{:ok, body, conn}`)
      is stored in `conn.assigns[:raw_body]` before the body goes to the
      parser. A later read returns the cached body.
    * Every other request reads straight through `Plug.Conn.read_body/2`, so no
      second copy of the body is kept.
    * `{:more, partial, conn}` (a body over the parser `:length`) and
      `{:error, reason}` are returned unchanged on every path, so
      `Plug.Parsers` answers an oversized body with
      `Plug.Parsers.RequestTooLargeError` (413) instead of crashing.

  ## Configuration

  In your endpoint (`lib/dhc_web/endpoint.ex`):

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library(),
        body_reader: {DhcWeb.CacheBodyReader, :read_body, []}

  Then in the webhook controller, access the raw body via:

      payload = conn.assigns[:raw_body]
  """

  @stripe_webhook_path "/api/webhooks/stripe"

  @doc """
  Reads the request body, caching it in `conn.assigns[:raw_body]` for the
  Stripe webhook path only.
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(%Plug.Conn{request_path: @stripe_webhook_path} = conn, opts) do
    case conn.assigns[:raw_body] do
      nil -> conn |> Plug.Conn.read_body(opts) |> cache()
      cached -> {:ok, cached, conn}
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp cache({:ok, body, conn}), do: {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
  defp cache(other), do: other
end
