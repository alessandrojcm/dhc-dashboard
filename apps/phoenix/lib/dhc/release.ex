defmodule Dhc.Release do
  @moduledoc """
  Runtime commands used by the production release.

  These functions are invoked from release scripts, where Mix is not available.
  """

  @app :dhc

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Imports the Waitlist spreadsheet export at `path` once (spec story 123)
  and prints the report. Run `dry_run: true` first:

      bin/dhc eval 'Dhc.Release.import_waitlist("/tmp/waitlist.tsv", dry_run: true)'

  Returns `{:ok, report}` or `{:error, reason}` when the sheet as a whole is
  refused (nothing written). Rows whose Paid cell is set get a `held`
  Carried Fee (`Dhc.BeginnersWorkshops.import_waitlist/2`). See
  `Dhc.Waitlist.Import`.
  """
  @spec import_waitlist(Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def import_waitlist(path, opts \\ []) do
    load_app()
    contents = File.read!(path)

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Dhc.Repo, fn _repo ->
        Dhc.BeginnersWorkshops.import_waitlist(contents, Keyword.take(opts, [:dry_run]))
      end)

    case result do
      {:ok, report} ->
        report |> Dhc.Waitlist.Import.format_report() |> Enum.each(&IO.puts/1)
        {:ok, report}

      {:error, reason} ->
        IO.puts("Waitlist import refused: #{reason}")
        {:error, reason}
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
