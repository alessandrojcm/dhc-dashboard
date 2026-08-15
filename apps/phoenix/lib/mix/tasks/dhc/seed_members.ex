defmodule Mix.Tasks.Dhc.SeedMembers do
  @moduledoc """
  Compatibility alias for the development member seed task.

  ## Usage

      mix dhc.seed_members
      mix dhc.seed_members 25

  Prefer `mix seed.members`; both commands create Phoenix Principals directly.
  The task is development-only because its implementation and Faker dependency
  are only compiled in the development environment.
  """

  use Mix.Task

  @shortdoc "Seed fake active members (development only)"

  @impl Mix.Task
  def run(args) do
    if Mix.env() != :dev do
      Mix.raise("dhc.seed_members is development-only; run it with MIX_ENV=dev")
    end

    Mix.Task.run("seed.members", args)
  end
end
