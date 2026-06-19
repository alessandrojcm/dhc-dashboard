defmodule Mix.Tasks.Seed.Members do
  @moduledoc """
  Seeds fake active member accounts, profiles, roles, and member profiles.

  ## Usage

      mix seed.members
      mix seed.members 25

  Auth users are created through the Supabase Admin API. Run via `mise run
  seed-members` so repo-root `.env` is loaded before Mix starts.
  """

  use Mix.Task

  @shortdoc "Seed fake active members"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    count = parse_count(args, 10)
    Dhc.DevSeeds.seed_members(count)
    Mix.shell().info("Successfully seeded #{count} member(s)")
  end

  defp parse_count([], default), do: default

  defp parse_count([value], _default) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> Mix.raise("count must be a positive integer")
    end
  end

  defp parse_count(_args, _default), do: Mix.raise("usage: mix seed.members [count]")
end
