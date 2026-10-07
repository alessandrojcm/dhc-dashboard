defmodule Dhc.Auth.Retention do
  @moduledoc """
  Deletes auth rows that can no longer affect anything.

    * `principal_tokens` — magic-link, session and socket rows past their
      context's validity (`Dhc.Auth.PrincipalToken.validity_seconds/1`) plus a
      safety margin. Socket tokens are minted on every socket connect and
      session rows are never removed on expiry, so without this the table
      only grows.
    * `auth_rate_limit_windows` — magic-link rate-limit counters
      (`DhcWeb.Plugs.MagicLinkRateLimit`) whose window started more than a
      day ago. The longest window is one hour, so an older row can never be
      the current window again.

  Deletes run in bounded batches, each its own statement, so a large backlog
  never holds row locks or a long transaction. Driven daily by
  `Dhc.Auth.Workers.TokenRetentionWorker`.
  """

  import Ecto.Query

  alias Dhc.Auth.PrincipalToken
  alias Dhc.Repo

  @token_margin_seconds 24 * 60 * 60
  @rate_limit_window_retention_seconds 24 * 60 * 60
  @default_batch_size 1_000

  @type result :: %{principal_tokens: non_neg_integer(), rate_limit_windows: non_neg_integer()}

  @doc """
  Prunes expired tokens and stale rate-limit windows; returns how many rows
  of each were deleted.

  Options: `:now` (default `DateTime.utc_now/0`) and `:batch_size` (default
  #{@default_batch_size}).
  """
  @spec prune(keyword()) :: result()
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    %{
      principal_tokens: prune_tokens(now, batch_size),
      rate_limit_windows: prune_rate_limit_windows(now, batch_size)
    }
  end

  defp prune_tokens(now, batch_size) do
    batch =
      from t in PrincipalToken.expired_query(now, @token_margin_seconds),
        select: t.id,
        limit: ^batch_size

    in_batches(batch_size, fn ->
      {count, _rows} = Repo.delete_all(from t in PrincipalToken, where: t.id in subquery(batch))
      count
    end)
  end

  # The table has no primary key (rows are unique on `(key, window_start)`),
  # so a batch is addressed by `ctid`.
  defp prune_rate_limit_windows(now, batch_size) do
    cutoff = DateTime.add(now, -@rate_limit_window_retention_seconds)

    in_batches(batch_size, fn ->
      %{num_rows: count} =
        Repo.query!(
          """
          DELETE FROM auth_rate_limit_windows
          WHERE ctid IN (
            SELECT ctid FROM auth_rate_limit_windows WHERE window_start < $1 LIMIT $2
          )
          """,
          [cutoff, batch_size]
        )

      count
    end)
  end

  defp in_batches(batch_size, delete_batch, total \\ 0) do
    case delete_batch.() do
      ^batch_size -> in_batches(batch_size, delete_batch, total + batch_size)
      count -> total + count
    end
  end
end
