defmodule Dhc.ConcurrencyHelpers do
  @moduledoc """
  Real-connection helpers for PostgreSQL concurrency tests.

  `Ecto.Adapters.SQL.Sandbox.allow/3` inside a `Task` shares the one sandbox
  connection and serialises the work, so it cannot prove a lock. These helpers
  run on independent connections via `unboxed_run/2`. Do not nest
  `outside_sandbox/1` — an inner call checks the outer connection back in.
  """

  import ExUnit.Assertions

  alias Dhc.Repo
  alias Ecto.Adapters.SQL.Sandbox

  def outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  @doc """
  Hold a row lock, start the competing commands, prove they are queued
  behind it, then release. Without the held lock a ready/go barrier can
  let one command finish before the other opens its transaction.
  """
  def hold_lock_then(sql, params, funs) do
    parent = self()
    holder = Task.async(fn -> hold_row_lock(sql, params, parent) end)

    assert_receive :locked, 5_000

    tasks = Enum.map(funs, fn fun -> Task.async(fn -> outside_sandbox(fun) end) end)

    try do
      :ok = wait_for_lock_waiter("%")

      Enum.each(tasks, fn task ->
        assert Task.yield(task, 200) == nil
      end)
    after
      send(holder.pid, :release)
    end

    assert {:ok, _} = Task.await(holder, 5_000)
    Enum.map(tasks, &Task.await(&1, :infinity))
  end

  def hold_row_lock(sql, params, parent) do
    outside_sandbox(fn ->
      Repo.transaction(fn ->
        Repo.query!(sql, params)
        send(parent, :locked)
        receive do: (:release -> :ok)
      end)
    end)
  end

  @doc """
  Blocks — inside Postgres, not the test process — until some other
  backend is waiting on an ungranted lock whose `query` matches the
  LIKE pattern. Activity stats are snapshotted per transaction, so the
  loop clears the snapshot each iteration.
  """
  def wait_for_lock_waiter(query_pattern \\ "%") when is_binary(query_pattern) do
    Repo.query!(
      """
      DO $$
      DECLARE attempts int := 0;
      BEGIN
        LOOP
          EXIT WHEN EXISTS (
            SELECT 1
            FROM pg_locks blocked
            JOIN pg_stat_activity a ON a.pid = blocked.pid
            WHERE NOT blocked.granted
              AND blocked.pid <> pg_backend_pid()
              AND a.query ILIKE '#{query_pattern}'
          );
          attempts := attempts + 1;
          IF attempts > 500 THEN
            RAISE EXCEPTION 'no backend queued behind the held lock';
          END IF;
          PERFORM pg_sleep(0.01);
          PERFORM pg_stat_clear_snapshot();
        END LOOP;
      END
      $$
      """,
      []
    )

    :ok
  end
end
