defmodule Dhc.BeginnersWorkshops.LockTrace do
  @moduledoc """
  Records the row locks and writes a process issues against the Beginners'
  Workshop tables, grouped by transaction, so tests can assert the ADR 0029
  lock order (Beginners' Workshop → Waitlist entry → Intake → Carried Fee →
  payment → refund) and that no payment write happens outside a transaction
  — the `Dhc.Workshops.PaymentLockTrace` shape.

  It listens to `[:dhc, :repo, :query]` telemetry, which runs synchronously
  in the querying process, so a trace only sees the calling process's
  queries.
  """

  @ranks %{
    "beginners_workshops" => 0,
    "waitlist" => 1,
    "beginners_workshop_intakes" => 2,
    "beginners_workshop_intake_payments" => 4
  }

  @doc "Runs `fun` and returns `{result, events}` for the calling process."
  def trace(fun) do
    id = {__MODULE__, make_ref()}
    pid = self()
    Process.put(id, [])

    :ok = :telemetry.attach(id, [:dhc, :repo, :query], &__MODULE__.record/4, %{id: id, pid: pid})

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
      {_max, upward} = Enum.reduce(tables, {-1, []}, &track_rank/2)
      Enum.reverse(upward)
    end)
  end

  defp track_rank(table, {max, upward}) do
    rank = Map.fetch!(@ranks, table)
    if rank < max, do: {max, [table | upward]}, else: {rank, upward}
  end

  @doc "Writes to Beginners' Workshop tables issued outside any transaction."
  def writes_outside_transaction(events), do: for({:write, table, false} <- events, do: table)
end
