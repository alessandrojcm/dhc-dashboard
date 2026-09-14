defmodule Mix.Tasks.Seed.Inventory do
  @moduledoc """
  Seeds a realistic inventory catalog, storage hierarchy, items, and states.

  ## Usage

      mix seed.inventory
      mix seed.inventory 30

  Run via `mise run seed-inventory` so repo-root `.env` is loaded before Mix
  starts.
  """

  use Mix.Task

  @shortdoc "Seed inventory structure, items, loans, and maintenance"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    count = parse_count(args, 24)
    Dhc.DevSeeds.seed_inventory(count)
    Mix.shell().info("Successfully seeded #{count} inventory item(s)")
  end

  defp parse_count([], default), do: default

  defp parse_count([value], _default) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> Mix.raise("count must be a positive integer")
    end
  end

  defp parse_count(_args, _default), do: Mix.raise("usage: mix seed.inventory [count]")
end
