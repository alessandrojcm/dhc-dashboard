defmodule Mix.Tasks.Dhc.DestinationBackfill.Apply do
  @shortdoc "Applies explicitly approved destination enrichments to upcoming workshops"
  @moduledoc """
  Applies a reviewed destination backfill plan (`Dhc.DestinationBackfill.apply_plan/3`)
  as an authorized staff principal and prints per-target outcomes as JSON.

      mix dhc.destination_backfill.apply PLAN.json --operator PRINCIPAL_ID

  `PLAN.json` holds the reviewed `mapping` and the `approved_targets` copied
  from a preview's `proposed_targets`. Each target is re-read under its
  owner's lock; stale, rescheduled, cancelled, started or unreviewed targets
  are refused and reported, never overwritten. Matches that were not approved
  are reported as `discovered` and left unchanged.

  Accepted changes record Calendar intent. While Calendar sending is active,
  attendees' existing events are updated through the normal synchronization
  protocol, and Google may send its own update emails; no workshop email is
  queued. Run only in an authorized operator session.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [operator: :string]) do
      {[operator: operator], [path], []} -> apply!(path, operator)
      _invalid -> usage!()
    end
  end

  defp apply!(path, operator) do
    plan = Mix.Tasks.Dhc.DestinationBackfill.Preview.read_json!(path)

    # Like Calendar activation, apply runs the application so Calendar intent
    # is queued through the ordinary Oban instance.
    Mix.Task.run("app.start")

    case Dhc.DestinationBackfill.apply_plan(plan, {:staff, operator}) do
      {:ok, result} -> Mix.shell().info(Jason.encode!(result, pretty: true))
      {:error, issues} -> Mix.raise("Plan refused: #{Jason.encode!(issues)}")
    end
  end

  defp usage!,
    do: Mix.raise("usage: mix dhc.destination_backfill.apply PLAN.json --operator PRINCIPAL_ID")
end
