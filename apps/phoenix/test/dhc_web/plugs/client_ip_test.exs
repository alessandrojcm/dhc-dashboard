defmodule DhcWeb.Plugs.ClientIpTest do
  # async: false — one test removes the global :trusted_forwarding_secret.
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]

  alias DhcWeb.Plugs.ClientIp

  # config/test.exs
  @secret "trusted-forwarding-test-secret"

  defp conn(remote_ip \\ {10, 0, 0, 1}) do
    %{Plug.Test.conn(:post, "/api/auth/magic-link") | remote_ip: remote_ip}
  end

  defp forwarded(conn, ip, secret) do
    conn
    |> put_req_header("x-dhc-client-ip", ip)
    |> put_req_header("x-dhc-forwarding-secret", secret)
  end

  describe "trusted SvelteKit forwarding" do
    test "uses x-dhc-client-ip when the forwarding secret matches" do
      assert conn() |> forwarded("203.0.113.7", @secret) |> ClientIp.to_string() ==
               "203.0.113.7"
    end

    test "prefers the trusted header over fly-client-ip" do
      conn =
        conn()
        |> put_req_header("fly-client-ip", "198.51.100.9")
        |> forwarded("203.0.113.7", @secret)

      assert ClientIp.to_string(conn) == "203.0.113.7"
    end

    test "ignores x-dhc-client-ip with a wrong secret" do
      assert conn() |> forwarded("203.0.113.7", "wrong") |> ClientIp.to_string() == "10.0.0.1"
    end

    test "ignores x-dhc-client-ip without a secret" do
      conn = put_req_header(conn(), "x-dhc-client-ip", "203.0.113.7")

      assert ClientIp.to_string(conn) == "10.0.0.1"
    end

    test "a spoofed header with a wrong secret falls back to fly-client-ip" do
      conn =
        conn()
        |> put_req_header("fly-client-ip", "198.51.100.9")
        |> forwarded("203.0.113.7", "wrong")

      assert ClientIp.to_string(conn) == "198.51.100.9"
    end

    test "ignores an unparseable x-dhc-client-ip" do
      assert conn() |> forwarded("not-an-ip", @secret) |> ClientIp.to_string() == "10.0.0.1"
    end

    test "ignores x-dhc-client-ip when no secret is configured" do
      previous = Application.get_env(:dhc, :trusted_forwarding_secret)
      Application.delete_env(:dhc, :trusted_forwarding_secret)
      on_exit(fn -> Application.put_env(:dhc, :trusted_forwarding_secret, previous) end)

      assert conn() |> forwarded("203.0.113.7", "") |> ClientIp.to_string() == "10.0.0.1"
    end
  end

  describe "fallbacks" do
    test "honours fly-client-ip" do
      conn = put_req_header(conn(), "fly-client-ip", "198.51.100.9")

      assert ClientIp.to_string(conn) == "198.51.100.9"
    end

    test "never trusts x-forwarded-for" do
      conn = put_req_header(conn(), "x-forwarded-for", "203.0.113.7")

      assert ClientIp.to_string(conn) == "10.0.0.1"
    end

    test "falls back to remote_ip" do
      assert ClientIp.resolve(conn()) == {10, 0, 0, 1}
    end
  end

  describe "IPv6" do
    test "formats a remote_ip tuple in colon notation" do
      assert conn({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) |> ClientIp.to_string() == "2001:db8::1"
    end

    test "accepts a forwarded IPv6 address" do
      assert conn() |> forwarded("2001:db8::7", @secret) |> ClientIp.to_string() ==
               "2001:db8::7"
    end
  end
end
