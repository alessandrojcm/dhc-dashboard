defmodule DhcWeb.Plugs.IntakeLinkPage do
  @moduledoc """
  The `:intake_link` pipeline plug for the public Intake link endpoints
  (ALE-381): the response sends `Referrer-Policy: no-referrer` and
  `Cache-Control: no-store`, and the request is logged with its token
  redacted (Phoenix's own request line is off for these paths, see
  `DhcWeb.IntakeLinkPrivacy.log_level/1`). The client IP comes from the
  `DhcWeb.Plugs.ClientIp` seam, so a SvelteKit-forwarded request logs the
  person's address rather than the server's.
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  alias DhcWeb.IntakeLinkPrivacy
  alias DhcWeb.Plugs.ClientIp

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Logger.info(fn -> request_line(conn) end)

    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex")
  end

  @doc "The request log line: method, redacted path and the client IP."
  @spec request_line(Plug.Conn.t()) :: String.t()
  def request_line(conn),
    do:
      "#{conn.method} #{IntakeLinkPrivacy.redact(conn.request_path)} from #{ClientIp.to_string(conn)}"
end
