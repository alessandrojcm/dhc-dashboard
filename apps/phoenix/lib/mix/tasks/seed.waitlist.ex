defmodule Mix.Tasks.Seed.Waitlist do
  @moduledoc """
  Seeds fake inactive waitlist profiles and waitlist rows.

  ## Usage

      mix seed.waitlist
      mix seed.waitlist 50
  """

  use Mix.Task

  @shortdoc "Seed fake waitlist entries"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    count = parse_count(args, 10)
    Dhc.DevSeeds.seed_waitlist(count)
    Mix.shell().info("Successfully seeded #{count} waitlist entries")
  end

  defp parse_count([], default), do: default

  defp parse_count([value], _default) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> Mix.raise("count must be a positive integer")
    end
  end

  defp parse_count(_args, _default), do: Mix.raise("usage: mix seed.waitlist [count]")
end
