defmodule Dhc.Workshops.PaymentLockTrace do
  @moduledoc """
  Records the row locks and writes a process issues against the Workshop
  payment tables, grouped by transaction, so tests can assert the lock order
  of ADR 0027 (Workshop → Payment Attempt → Registration → Refund) and that no
  payment write happens outside a transaction.

  It listens to `[:dhc, :repo, :query]` telemetry, which runs synchronously in
  the querying process, so a trace only sees the calling process's queries.

  `pause_after/2` reuses the same hook as a deterministic interleaving point:
  the querying process stops right after a matching query — still holding
  whatever locks its transaction took — until the test resumes it.
  """

  @ranks %{
    "club_activities" => 0,
    "club_activity_payment_attempts" => 1,
    "club_activity_registrations" => 2,
    "club_activity_refunds" => 3
  }

  @doc "Runs `fun` and returns `{result, events}` for the calling process."
  def trace(fun) do
    id = {__MODULE__, make_ref()}
    pid = self()
    Process.put(id, [])

    :ok =
      :telemetry.attach(id, [:dhc, :repo, :query], &__MODULE__.record/4, %{id: id, pid: pid})

    try do
      result = fun.()
      {result, Enum.reverse(Process.get(id))}
    after
      :telemetry.detach(id)
      Process.delete(id)
    end
  end

  @doc false
  def record(_event, _measurements, meta, %{id: id, pid: pid}) do
    if self() == pid do
      case classify(meta) do
        nil -> :ok
        event -> Process.put(id, [event | Process.get(id, [])])
      end
    end
  end

  defp classify(%{query: query} = meta) when is_binary(query) do
    cond do
      query == "begin" -> :begin
      query in ["commit", "rollback"] -> :commit
      not Map.has_key?(@ranks, meta.source) -> nil
      locking?(query) -> {:lock, meta.source}
      write?(query) -> {:write, meta.source, Dhc.Repo.in_transaction?()}
      true -> nil
    end
  end

  defp classify(_meta), do: nil

  defp locking?(query),
    do: String.starts_with?(query, "SELECT") and query =~ ~r/ FOR (UPDATE|SHARE|NO KEY UPDATE)/

  defp write?(query),
    do: String.starts_with?(query, "UPDATE") or String.starts_with?(query, "INSERT")

  @doc "Each transaction's locked tables, in acquisition order."
  def transactions(events) do
    events
    |> Enum.chunk_while(
      nil,
      fn
        :begin, _acc -> {:cont, []}
        :commit, nil -> {:cont, nil}
        :commit, acc -> {:cont, Enum.reverse(acc), nil}
        {:lock, table}, acc when is_list(acc) -> {:cont, [table | acc]}
        _event, acc -> {:cont, acc}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, Enum.reverse(acc), nil}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  @doc "Every lock taken on a table ranked below one the same transaction already holds."
  def upward_locks(events) do
    events
    |> transactions()
    |> Enum.flat_map(fn tables ->
      {_max, upward} =
        Enum.reduce(tables, {-1, []}, fn table, {max, upward} ->
          rank = Map.fetch!(@ranks, table)
          if rank < max, do: {max, [table | upward]}, else: {rank, upward}
        end)

      Enum.reverse(upward)
    end)
  end

  @doc "Payment-table writes issued outside any transaction."
  def writes_outside_transaction(events) do
    for {:write, table, false} <- events, do: table
  end

  @doc """
  Makes the calling process stop once, right after its first query matching
  `predicate`, and send `{:paused, pid}` to `notify`. It continues when it
  receives `:resume`.
  """
  def pause_after(notify, predicate) do
    id = {__MODULE__, :pause, make_ref()}

    :ok =
      :telemetry.attach(id, [:dhc, :repo, :query], &__MODULE__.maybe_pause/4, %{
        pid: self(),
        notify: notify,
        predicate: predicate,
        id: id
      })

    id
  end

  @doc false
  def maybe_pause(_event, _measurements, meta, %{pid: pid} = config) do
    if self() == pid and not Process.get(config.id, false) and config.predicate.(meta) do
      Process.put(config.id, true)
      send(config.notify, {:paused, self()})

      receive do
        :resume -> :ok
      after
        10_000 -> :ok
      end
    end
  end

  @doc "A predicate matching a query on `table` whose SQL starts with `verb`."
  def query_on(table, verb \\ "SELECT") do
    fn meta ->
      meta.source == table and is_binary(meta.query) and String.starts_with?(meta.query, verb)
    end
  end
end
