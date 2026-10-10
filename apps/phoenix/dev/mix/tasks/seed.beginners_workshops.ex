defmodule Mix.Tasks.Seed.BeginnersWorkshops do
  @moduledoc """
  Schedules Beginners' Workshops through the `Dhc.BeginnersWorkshops`
  boundary, as a seeded beginners coordinator (`beginners.seeder@example.com`).

  ## Usage

      mix seed.beginners_workshops
      mix seed.beginners_workshops 6

  Run via `mise run seed-beginners-workshops` so repo-root `.env` is loaded
  before Mix starts.
  """

  use Mix.Task

  @shortdoc "Seed scheduled Beginners' Workshops"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    count = parse_count(args, 3)
    Dhc.DevSeeds.seed_beginners_workshops(count)
    Mix.shell().info("Successfully scheduled #{count} Beginners' Workshop(s)")
  end

  defp parse_count([], default), do: default

  defp parse_count([value], _default) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> Mix.raise("count must be a positive integer")
    end
  end

  defp parse_count(_args, _default),
    do: Mix.raise("usage: mix seed.beginners_workshops [count]")
end
