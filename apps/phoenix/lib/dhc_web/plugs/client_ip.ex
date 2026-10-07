defmodule DhcWeb.Plugs.ClientIp do
  @moduledoc """
  Resolves the IP address of the end user behind a request.

  Phoenix is reached two ways: browsers call it directly through Fly's edge,
  and the SvelteKit server calls it server-side (SSR loads, remote functions)
  on the user's behalf. In the second case `conn.remote_ip` is the SvelteKit
  server's egress address, so any per-IP policy keyed on it would be shared by
  the whole club.

  Precedence:

    1. `x-dhc-client-ip`, **only** when the request also carries
       `x-dhc-forwarding-secret` equal (constant-time) to the configured
       `:trusted_forwarding_secret`. The SvelteKit server sets both headers
       from `event.getClientAddress()`. When the secret is unset, or the
       header is missing, wrong, or not a parseable IP, the header is ignored.
    2. `fly-client-ip`. Fly's proxy overwrites this header on every request
       it forwards, so a client cannot spoof it as long as Phoenix is only
       reachable through Fly's edge. If Phoenix is ever exposed without Fly
       in front, this step must be removed.
    3. `conn.remote_ip`.

  `x-forwarded-for` is never consulted: every hop appends to it, and the
  client controls its leftmost value.
  """

  @client_ip_header "x-dhc-client-ip"
  @secret_header "x-dhc-forwarding-secret"
  @fly_client_ip_header "fly-client-ip"

  @doc "The resolved client IP as an `:inet` address tuple."
  @spec resolve(Plug.Conn.t()) :: :inet.ip_address()
  def resolve(%Plug.Conn{} = conn) do
    trusted_forwarded_ip(conn) || header_ip(conn, @fly_client_ip_header) || conn.remote_ip
  end

  @doc "The resolved client IP formatted as a string (IPv4 dotted, IPv6 colon notation)."
  @spec to_string(Plug.Conn.t()) :: String.t()
  def to_string(%Plug.Conn{} = conn) do
    conn |> resolve() |> :inet.ntoa() |> List.to_string()
  end

  defp trusted_forwarded_ip(conn) do
    if trusted_forwarder?(conn), do: header_ip(conn, @client_ip_header)
  end

  defp trusted_forwarder?(conn) do
    with secret when is_binary(secret) and secret != "" <-
           Application.get_env(:dhc, :trusted_forwarding_secret),
         [presented] <- Plug.Conn.get_req_header(conn, @secret_header) do
      Plug.Crypto.secure_compare(presented, secret)
    else
      _ -> false
    end
  end

  defp header_ip(conn, header) do
    with [value] <- Plug.Conn.get_req_header(conn, header),
         {:ok, ip} <-
           value |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      ip
    else
      _ -> nil
    end
  end
end
