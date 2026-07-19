defmodule DhcWeb.Plugs.MagicLinkRateLimit do
  @moduledoc """
  Rate-limits `POST /api/auth/magic-link` requests.

  Policy (per `docs/auth-migration-specification.md`):
    * 3 requests per normalized email per 15 minutes
    * 10 requests per IP per hour
    * responses remain generic — a limited, unknown, or inactive address all
      return the same 200 `{"data":{"sent":true}}` shape (non-enumerating)

  The plug reads `params["email"]` (normalized) and the request IP. It
  increments two counters (email-window and ip-window) and refuses with 200
  + the generic body when either limit is exceeded — never 429, which would
  distinguish "over the limit" from "no Principal". Hitting the IP limit
  also does **not** insert the email-window counter, so a flood from one IP
  cannot mask which addresses it was probing.

  ## Implementation

  Counters live in `auth_rate_limit_windows`, keyed by
  `"magic_link:email:<normalized>"` and `"magic_link:ip:<ip>"`. Each window
  row is `(key, window_start, count)` with `window_start` aligned to the
  epoch boundary (15-min for email, 1-hour for IP). The check-and-increment
  is a single SQL `INSERT ... ON CONFLICT DO UPDATE` so it is atomic under
  the Ecto sandbox and across concurrent requests.

  ## Telemetry

  Emits `[:dhc, :auth, :magic_link, :rate_limited]` each time a request is
  refused, with `%{limit: :email | :ip}` (no PII). The controller emits the
  success/unknown paths; this plug emits only refusals.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Dhc.Repo

  @email_window_seconds 15 * 60
  @email_max_per_window 3
  @ip_window_seconds 60 * 60
  @ip_max_per_window 10

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, email_key} <- email_window_key(conn),
         {:ok, ip_key} <- ip_window_key(conn),
         :ok <- check_window(ip_key, @ip_window_seconds, @ip_max_per_window, :ip),
         :ok <- check_window(email_key, @email_window_seconds, @email_max_per_window, :email) do
      conn
    else
      {:error, :no_email} ->
        # No usable email — still pretend we sent. Don't count toward IP
        # either, since the request didn't get far enough to probe.
        generic_ok(conn)

      {:error, {:limited, limit}} ->
        :telemetry.execute(
          [:dhc, :auth, :magic_link, :rate_limited],
          %{limit: limit},
          %{}
        )

        generic_ok(conn)
    end
  end

  defp generic_ok(conn) do
    conn
    |> put_status(:ok)
    |> json(%{data: %{sent: true}})
    |> halt()
  end

  defp email_window_key(conn) do
    case conn.params do
      %{"email" => email} when is_binary(email) and email != "" ->
        normalized = Dhc.Auth.Principal.normalize_email(email)
        {:ok, "magic_link:email:#{normalized}"}

      _ ->
        {:error, :no_email}
    end
  end

  defp ip_window_key(conn) do
    case remote_ip(conn) do
      nil -> {:error, :no_email}
      ip -> {:ok, "magic_link:ip:#{inet_to_string(ip)}"}
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: ip}), do: ip

  defp inet_to_string(ip) do
    :inet.ntoa(ip) |> to_string()
  end

  defp check_window(key, window_seconds, max, limit) do
    window_start = current_window_start(window_seconds)
    count = increment_window(key, window_start)

    if count <= max do
      :ok
    else
      {:error, {:limited, limit}}
    end
  end

  defp current_window_start(window_seconds) do
    now = System.system_time(:second)
    aligned = now - rem(now, window_seconds)
    DateTime.from_unix!(aligned)
  end

  defp increment_window(key, window_start) do
    # Atomic check-and-increment. `INSERT ... ON CONFLICT (key, window_start)
    # DO UPDATE SET count = auth_rate_limit_windows.count + 1` returns the
    # new count. We use a raw query because Ecto doesn't speak upsert with
    # returning cleanly across the sandbox without a schema, and we don't
    # want a schema here (this is the only read/write site). The table has
    # only `created_at` (no `updated_at`) because window rows are immutable
    # once written — `timestamps(updated_at: false)` in the migration.
    %{rows: [[count]]} =
      Repo.query!(
        """
        INSERT INTO auth_rate_limit_windows (key, window_start, count, created_at)
        VALUES ($1, $2, 1, NOW())
        ON CONFLICT (key, window_start)
        DO UPDATE SET count = auth_rate_limit_windows.count + 1
        RETURNING count
        """,
        [key, window_start]
      )

    count
  end
end
