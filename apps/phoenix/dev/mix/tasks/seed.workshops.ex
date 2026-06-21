defmodule Mix.Tasks.Seed.Workshops do
  @moduledoc """
  Seeds fake Workshops with interest, registrations, and refunds.

  ## Usage

      mix seed.workshops
      mix seed.workshops 5

  Auth users are created through the Supabase Admin API. Run via `mise run
  seed-workshops` so repo-root `.env` is loaded before Mix starts.
  """

  use Mix.Task

  @shortdoc "Seed fake workshops"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    count = parse_count(args, 5)
    Dhc.DevSeeds.seed_workshops(count)
    Mix.shell().info("Successfully seeded #{count} workshop(s)")
  end

  defp parse_count([], default), do: default

  defp parse_count([value], _default) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> Mix.raise("count must be a positive integer")
    end
  end

  defp parse_count(_args, _default), do: Mix.raise("usage: mix seed.workshops [count]")
end
