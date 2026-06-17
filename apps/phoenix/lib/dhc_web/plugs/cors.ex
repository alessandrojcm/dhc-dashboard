defmodule DhcWeb.Plugs.Cors do
  @moduledoc """
  Handles browser CORS requests for the Phoenix JSON API.

  The SvelteKit app can call Phoenix directly from the browser through the
  generated `@dhc/api-client`, which sends Supabase JWTs in the Authorization
  header. That header triggers browser preflight requests, so OPTIONS requests
  must be answered before Phoenix route matching.
  """

  import Plug.Conn

  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @default_allowed_headers "authorization, content-type, accept"
  @max_age "86400"

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/api" <> _} = conn, _opts) do
    conn
    |> put_cors_headers()
    |> maybe_halt_preflight()
  end

  def call(conn, _opts), do: conn

  defp put_cors_headers(conn) do
    origin = get_req_header(conn, "origin") |> List.first()

    if allowed_origin?(origin) do
      requested_headers =
        get_req_header(conn, "access-control-request-headers")
        |> List.first()
        |> case do
          nil -> @default_allowed_headers
          headers -> headers
        end

      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("access-control-allow-methods", @allowed_methods)
      |> put_resp_header("access-control-allow-headers", requested_headers)
      |> put_resp_header("access-control-max-age", @max_age)
      |> put_resp_header("vary", "origin")
      |> maybe_put_private_network_header()
    else
      conn
    end
  end

  defp maybe_put_private_network_header(conn) do
    case get_req_header(conn, "access-control-request-private-network") do
      ["true" | _] -> put_resp_header(conn, "access-control-allow-private-network", "true")
      _ -> conn
    end
  end

  defp maybe_halt_preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(:no_content, "")
    |> halt()
  end

  defp maybe_halt_preflight(conn), do: conn

  defp allowed_origin?(nil), do: false

  defp allowed_origin?(origin) do
    :dhc
    |> Application.get_env(:cors_allowed_origins, [])
    |> Enum.member?(origin)
  end
end
