defmodule Dhc.Resend.RateLimit do
  @moduledoc """
  One Resend request budget across sending jobs, batches, receiving reads and
  Phoenix nodes. PostgreSQL admits one request every 125ms (8/s, below the
  account's 10/s ceiling). Idle time never accumulates burst credit.

  Only the admission query holds a connection: waiting and HTTP happen outside
  transactions. A 429 extends the shared cooldown before Oban retries the job.
  This cannot coordinate other applications using the same Resend account.
  """

  alias Dhc.Repo

  @interval_ms 125

  @doc "Waits for admission in production; dev/test providers are not throttled."
  def await do
    if Application.get_env(:dhc, :environment) == :prod do
      if Repo.in_transaction?(), do: raise("Resend requests must run outside transactions")
      wait_for_slot()
    else
      :ok
    end
  end

  defp wait_for_slot do
    case take() do
      :ok ->
        :ok

      {:wait, milliseconds} ->
        Process.sleep(milliseconds)
        wait_for_slot()
    end
  end

  @doc false
  # A supplied millisecond instant is the deterministic test clock. Production
  # uses the database clock, so node clock skew cannot multiply the allowance.
  def take(now_ms \\ nil) do
    result =
      Repo.query!(
        """
        INSERT INTO resend_request_gate AS gate (name, next_at_ms)
        SELECT 'resend', COALESCE($1::bigint, floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) + #{@interval_ms}
        ON CONFLICT (name) DO UPDATE SET next_at_ms = EXCLUDED.next_at_ms
        WHERE gate.next_at_ms <= EXCLUDED.next_at_ms - #{@interval_ms}
        RETURNING next_at_ms
        """,
        [now_ms]
      )

    if result.num_rows == 1, do: :ok, else: {:wait, @interval_ms}
  end

  @doc "Extends the account cooldown after a rate-limit response."
  def cooldown(headers) do
    milliseconds = retry_after_ms(headers)

    Repo.query!(
      """
      INSERT INTO resend_request_gate AS gate (name, next_at_ms)
      VALUES ('resend', floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint + $1::bigint)
      ON CONFLICT (name) DO UPDATE SET next_at_ms = GREATEST(gate.next_at_ms, EXCLUDED.next_at_ms)
      """,
      [milliseconds]
    )

    :ok
  end

  defp retry_after_ms(headers) do
    value =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(key) == "retry-after", do: value
      end)

    case Float.parse(to_string(value)) do
      {seconds, ""} when seconds > 0 -> min(60_000, max(1_000, ceil(seconds * 1_000)))
      _ -> 1_000
    end
  end
end
