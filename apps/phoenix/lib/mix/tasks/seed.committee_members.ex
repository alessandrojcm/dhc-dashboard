defmodule Mix.Tasks.Seed.CommitteeMembers do
  @moduledoc """
  Seeds committee/member accounts from a CSV file.

  ## Usage

      mix seed.committee_members
      mix seed.committee_members ../../scripts/users.csv

  Expected columns match the legacy `scripts/users.csv` format:
  `email,displayname,roles,first_name,last_name,dob,pronouns,gender,next_of_kin_name,next_of_kin_phone,preferred_weapon,additional_data`.
  """

  use Mix.Task

  @shortdoc "Seed committee members from CSV"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    csv_path = parse_csv_path(args)
    Dhc.DevSeeds.seed_committee_members(csv_path)
    Mix.shell().info("Finished processing committee CSV: #{csv_path}")
  end

  defp parse_csv_path([]), do: parse_csv_path(["../../scripts/users.csv"])

  defp parse_csv_path([path]) do
    candidates = [Path.expand(path), Path.expand("../..", File.cwd!()) |> Path.join(path)]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> Mix.raise("CSV file not found: #{path}")
      expanded -> expanded
    end
  end

  defp parse_csv_path(_args),
    do: Mix.raise("usage: mix seed.committee_members [path/to/users.csv]")
end
