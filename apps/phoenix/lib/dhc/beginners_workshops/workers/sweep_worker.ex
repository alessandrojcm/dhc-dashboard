defmodule Dhc.BeginnersWorkshops.Workers.SweepWorker do
  @moduledoc """
  ALE-380: the one periodic Beginners' Workshop sweep. Every few minutes it
  calls `Dhc.BeginnersWorkshops.run_due_passes/0`, which runs each due
  time-driven pass through the boundary as `:system`.

  The ledger is the schedule (the `Dhc.Inventory.LoanReminders` precedent):
  Batches, Intake states and the Intake Email log decide what is owed, so a
  missed tick, an overlapping tick or a crashed job all leave the same
  evidence and the next tick repairs it. There are no per-workshop jobs, so
  a reschedule needs no job rewrites. A failed pass is logged and retried by
  the next tick rather than by retrying the job.

  Cron enqueues it with no args. An optional `"at"` (ISO 8601 instant) pins
  the clock the passes are judged at, for wiring tests and manual reruns.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  require Logger

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.Clock

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case BeginnersWorkshops.run_due_passes(clock_opts(args)) do
      %{failed: 0} ->
        :ok

      %{failed: failed} = tally ->
        Logger.warning(
          "[beginners-workshop-sweep] #{failed} pass(es) failed and will run again on the next sweep",
          Map.to_list(tally)
        )

        :ok
    end
  end

  defp clock_opts(%{"at" => at}) when is_binary(at) do
    {:ok, instant, _offset} = DateTime.from_iso8601(at)
    [clock: Clock.fixed(instant)]
  end

  defp clock_opts(_args), do: []
end
