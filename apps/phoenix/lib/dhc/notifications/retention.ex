defmodule Dhc.Notifications.Retention do
  @moduledoc """
  Deletes Notifications created more than three calendar months ago, read or
  unread. Driven nightly by `Dhc.Notifications.Workers.RetentionWorker`.

  Safe for keyed callers: a `create_keyed/3` key only deduplicates retries,
  which happen within minutes, and loan reminders keep their own ledger
  (`inventory_loan_reminders`), so pruning a reminder's row never makes it
  owed again. A Web Push job whose row has gone cancels itself.

  Deletes run in bounded batches, each its own statement, so a large backlog
  never holds row locks or a long transaction.
  """

  import Ecto.Query

  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @retention_months 3
  @default_batch_size 1_000

  @doc """
  Prunes expired Notifications and returns how many were deleted.

  Options: `:now` (default `DateTime.utc_now/0`) and `:batch_size` (default
  #{@default_batch_size}).
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    cutoff = cutoff(now)

    batch =
      from n in Notification,
        where: n.created_at < ^cutoff,
        select: n.id,
        limit: ^batch_size

    in_batches(batch_size, fn ->
      {count, _rows} = Repo.delete_all(from n in Notification, where: n.id in subquery(batch))
      count
    end)
  end

  @doc "The instant before which a Notification is pruned."
  @spec cutoff(DateTime.t()) :: DateTime.t()
  def cutoff(%DateTime{} = now), do: DateTime.shift(now, month: -@retention_months)

  defp in_batches(batch_size, delete_batch, total \\ 0) do
    case delete_batch.() do
      ^batch_size -> in_batches(batch_size, delete_batch, total + batch_size)
      count -> total + count
    end
  end
end
