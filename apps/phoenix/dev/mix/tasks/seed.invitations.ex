defmodule Mix.Tasks.Seed.Invitations do
  @moduledoc """
  Seeds fake pending member invitations.

  ## Usage

      mix seed.invitations
      mix seed.invitations 50
  """

  use Mix.Task

  @shortdoc "Seed fake pending invitations"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    count = parse_count(args, 10)
    Dhc.DevSeeds.seed_invitations(count)
    Mix.shell().info("Successfully seeded #{count} invitation(s)")
  end

  defp parse_count([], default), do: default

  defp parse_count([value], _default) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> count
      _ -> Mix.raise("count must be a positive integer")
    end
  end

  defp parse_count(_args, _default), do: Mix.raise("usage: mix seed.invitations [count]")
end
