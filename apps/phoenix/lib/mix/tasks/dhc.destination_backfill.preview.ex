defmodule Mix.Tasks.Dhc.DestinationBackfill.Preview do
  @shortdoc "Previews a reviewed venue → destination mapping for upcoming workshops"
  @moduledoc """
  Prints a read-only JSON preview of a reviewed destination backfill
  (`Dhc.DestinationBackfill.preview/2`): every upcoming workshop with its short
  label, schedule, status, current and proposed destination, outcome and
  expected Calendar effect, plus the `proposed_targets` an operator may copy
  into `approved_targets` for `mix dhc.destination_backfill.apply`.

      mix dhc.destination_backfill.preview MAPPING.json

  Makes no Google calls, database writes or job inserts, and never starts the
  application or its workers. Output contains no recipient addresses.
  """
  use Mix.Task

  @impl Mix.Task
  def run([path]) do
    document = read_json!(path)

    # Never `app.start`: see `Mix.Dhc.ReadOnlyRepo`.
    Mix.Dhc.ReadOnlyRepo.run(fn ->
      case Dhc.DestinationBackfill.parse_mapping(document) do
        {:ok, mapping} ->
          mapping
          |> Dhc.DestinationBackfill.preview()
          |> Jason.encode!(pretty: true)
          |> Mix.shell().info()

        {:error, issues} ->
          Mix.raise("Mapping refused: #{Jason.encode!(issues)}")
      end
    end)
  end

  def run(_args), do: Mix.raise("usage: mix dhc.destination_backfill.preview MAPPING.json")

  @doc false
  def read_json!(path) do
    with {:ok, body} <- File.read(path),
         {:ok, document} <- Jason.decode(body) do
      document
    else
      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("#{path} is not JSON: #{Exception.message(error)}")

      {:error, reason} ->
        Mix.raise("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end
end
