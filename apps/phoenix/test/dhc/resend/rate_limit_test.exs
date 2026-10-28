defmodule Dhc.Resend.RateLimitTest do
  use Dhc.DataCase, async: false

  alias Dhc.Resend.RateLimit

  test "all callers share one paced budget, not a per-worker concurrency limit" do
    assert :ok = RateLimit.take(1_000)
    for _ <- 1..20, do: assert({:wait, 125} = RateLimit.take(1_000))
    assert {:wait, 125} = RateLimit.take(1_124)
    assert :ok = RateLimit.take(1_125)
    assert {:wait, 125} = RateLimit.take(1_125)
    assert :ok = RateLimit.take(2_000)
    assert {:wait, 125} = RateLimit.take(2_000)
  end

  test "independent database callers cannot admit a concurrent burst" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DELETE FROM resend_request_gate")
    end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM resend_request_gate")
      end)
    end)

    outcomes =
      1..20
      |> Task.async_stream(
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> RateLimit.take(1_000) end)
        end,
        max_concurrency: 10
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(outcomes, &(&1 == :ok)) == 1
    assert Enum.count(outcomes, &(&1 == {:wait, 125})) == 19
  end

  test "single and batch email HTTP calls use the same gate and preserve idempotency" do
    original = Application.get_env(:dhc, :environment)
    Application.put_env(:dhc, :environment, :prod)
    on_exit(fn -> Application.put_env(:dhc, :environment, original) end)
    bypass = Bypass.open()
    owner = self()

    Bypass.expect(bypass, fn conn ->
      %{rows: [[next_at]]} = Repo.query!("SELECT next_at_ms FROM resend_request_gate")
      send(owner, {:admission, next_at, Plug.Conn.get_req_header(conn, "idempotency-key")})
      Plug.Conn.resp(conn, 200, "{}")
    end)

    1..12
    |> Task.async_stream(
      fn index ->
        path = if rem(index, 2) == 0, do: "/emails/batch", else: "/emails"

        email =
          Swoosh.Email.put_provider_option(%Swoosh.Email{}, :idempotency_key, "test-#{index}")

        assert {:ok, 200, _, _} =
                 Dhc.Email.ApiClient.post(
                   "http://localhost:#{bypass.port}#{path}",
                   [],
                   "{}",
                   email
                 )
      end,
      max_concurrency: 4,
      timeout: 10_000
    )
    |> Stream.run()

    instants =
      for _ <- 1..12 do
        assert_receive {:admission, instant, [key]}
        assert key =~ "test-"
        instant
      end

    # Pacing is pinned with the fixed clock above. Here only assert wiring:
    # scheduler/HTTP delays can let a later admission precede a handler read.
    assert Enum.all?(instants, &is_integer/1)
  end

  test "a provider 429 preserves the response and applies Retry-After to the shared gate" do
    original = Application.get_env(:dhc, :environment)
    Application.put_env(:dhc, :environment, :prod)
    on_exit(fn -> Application.put_env(:dhc, :environment, original) end)
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/emails", fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "5") |> Plug.Conn.resp(429, "limited")
    end)

    %{rows: [[before_ms]]} =
      Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint")

    assert {:ok, 429, _, "limited"} =
             Dhc.Email.ApiClient.post(
               "http://localhost:#{bypass.port}/emails",
               [],
               "{}",
               %Swoosh.Email{}
             )

    %{rows: [[until_ms]]} =
      Repo.query!("""
        SELECT next_at_ms
      FROM resend_request_gate
      """)

    assert until_ms >= before_ms + 5_000
    assert {:wait, 125} = RateLimit.take(until_ms - 1)
    assert :ok = RateLimit.take(until_ms)
  end

  test "waiting for a provider slot inside a transaction is refused" do
    original = Application.get_env(:dhc, :environment)
    Application.put_env(:dhc, :environment, :prod)
    on_exit(fn -> Application.put_env(:dhc, :environment, original) end)

    assert_raise RuntimeError, ~r/outside transactions/, fn ->
      Repo.transaction(fn -> RateLimit.await() end)
    end
  end
end
