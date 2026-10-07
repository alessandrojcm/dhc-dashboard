defmodule DhcWeb.Plugs.MagicLinkRateLimitTest do
  use DhcWeb.ConnCase, async: true

  alias Dhc.Repo

  import Ecto.Query

  # The plug is exercised end-to-end through /api/auth/magic-link in
  # `AuthSessionControllerTest`. These tests exercise the plug directly to
  # verify the IP-window and email-window policies and the non-enumerating
  # missing-email path, independent of the controller's response shape.
  #
  # Which limit fired is observable by inspecting the auth_rate_limit_windows
  # rows the plug wrote before deciding to halt — the email row's count is
  # >3 when the email limit fired, the IP row's count is >10 when the IP
  # limit fired. This avoids telemetry timing races.

  @ip "192.0.2.1"

  describe "email window (3 per 15 minutes)" do
    test "allows 3 and refuses the 4th for the same normalized email" do
      email = "rl-email-#{System.unique_integer([:positive])}@example.com"

      assert call(email, @ip) == :ok
      assert call(email, @ip) == :ok
      assert call(email, @ip) == :ok
      assert {:limited, :email} = call(email, @ip)
    end

    test "normalizes email before keying (case-insensitive)" do
      email = "rl-norm-#{System.unique_integer([:positive])}@example.com"

      assert call(String.upcase(email), @ip) == :ok
      assert call(email, @ip) == :ok
      assert call("  #{email}  ", @ip) == :ok
      assert {:limited, :email} = call(email, @ip)
    end
  end

  describe "IP window (10 per hour)" do
    test "allows 10 and refuses the 11th from the same IP regardless of email" do
      for i <- 1..10 do
        assert call("ip-#{i}@example.com", @ip) == :ok
      end

      assert {:limited, :ip} = call("ip-11@example.com", @ip)
    end

    test "a second IP has its own independent budget" do
      for _ <- 1..10, do: call("a-#{System.unique_integer([:positive])}@example.com", @ip)

      assert call("other@example.com", "192.0.2.2") == :ok
    end
  end

  describe "client IP from the SvelteKit server (trusted forwarding)" do
    # Every SSR call shares the SvelteKit egress address as remote_ip; the
    # forwarded browser address must key the IP window instead.
    @proxy_ip "192.0.2.50"
    @secret "trusted-forwarding-test-secret"

    test "two forwarded client IPs behind one proxy have independent budgets" do
      for i <- 1..10 do
        assert forwarded_call("fwd-a-#{i}@example.com", "198.51.100.1", @secret) == :ok
      end

      assert forwarded_call("fwd-a-11@example.com", "198.51.100.1", @secret) ==
               {:limited, :ip}

      assert forwarded_call("fwd-b@example.com", "198.51.100.2", @secret) == :ok
    end

    test "a spoofed x-dhc-client-ip with a wrong or missing secret keys on remote_ip" do
      proxy = "192.0.2.51"

      for i <- 1..5 do
        assert forwarded_call("spoof-a-#{i}@example.com", "198.51.100.#{i}", "wrong", proxy) ==
                 :ok

        assert forwarded_call("spoof-b-#{i}@example.com", "198.51.100.#{i}", nil, proxy) ==
                 :ok
      end

      assert forwarded_call("spoof-c@example.com", "198.51.100.99", "wrong", proxy) ==
               {:limited, :ip}

      refute Repo.exists?(
               from(w in "auth_rate_limit_windows",
                 where: like(w.key, "magic_link:ip:198.51.100.%")
               )
             )
    end
  end

  describe "non-enumerating on missing email" do
    test "short-circuits with the generic 200 body and does not consume the IP budget" do
      conn = conn_with_ip(@ip) |> plug_call(%{})

      assert conn.halted
      assert conn.status == 200
      assert Phoenix.json_library().decode!(conn.resp_body) == %{"data" => %{"sent" => true}}

      ip_pattern = "%#{@ip}%"

      refute Repo.exists?(from(w in "auth_rate_limit_windows", where: like(w.key, ^ip_pattern)))
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp call(email, ip) do
    conn = conn_with_ip(ip) |> plug_call(%{"email" => email})

    cond do
      not conn.halted -> :ok
      conn.status == 200 and ip_limited?(ip) -> {:limited, :ip}
      conn.status == 200 and email_limited?(email) -> {:limited, :email}
      true -> :ok
    end
  end

  defp forwarded_call(email, client_ip, secret, proxy_ip \\ @proxy_ip) do
    conn =
      proxy_ip
      |> conn_with_ip()
      |> Plug.Conn.put_req_header("x-dhc-client-ip", client_ip)

    conn =
      if secret, do: Plug.Conn.put_req_header(conn, "x-dhc-forwarding-secret", secret), else: conn

    conn = plug_call(conn, %{"email" => email})
    keyed_ip = if secret == @secret, do: client_ip, else: proxy_ip

    cond do
      not conn.halted -> :ok
      conn.status == 200 and ip_limited?(keyed_ip) -> {:limited, :ip}
      true -> :halted
    end
  end

  defp ip_limited?(ip) do
    key = "magic_link:ip:#{ip}"

    Repo.exists?(
      from(w in "auth_rate_limit_windows",
        where: w.key == ^key and w.count > 10
      )
    )
  end

  defp email_limited?(email) do
    normalized = Dhc.Auth.Principal.normalize_email(email)
    key = "magic_link:email:#{normalized}"

    Repo.exists?(
      from(w in "auth_rate_limit_windows",
        where: w.key == ^key and w.count > 3
      )
    )
  end

  defp conn_with_ip(ip_string) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(ip_string))
    %{conn() | remote_ip: ip}
  end

  defp plug_call(conn, params) do
    DhcWeb.Plugs.MagicLinkRateLimit.call(%{conn | params: params}, [])
  end
end
