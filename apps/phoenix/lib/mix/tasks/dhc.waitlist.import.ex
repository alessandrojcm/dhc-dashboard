defmodule Mix.Tasks.Dhc.Waitlist.Import do
  @moduledoc """
  Imports the club's Waitlist spreadsheet export (CSV or TSV) once.

      mix dhc.waitlist.import PATH --dry-run   # validate and report, write nothing
      mix dhc.waitlist.import PATH             # import

  Prints every imported row (with its Carried Fee from the Paid cell, raw),
  every refused row with its reason, and rows to review. A row whose Paid
  cell is set gets a `held` Carried Fee in the same transaction (through
  `Dhc.BeginnersWorkshops.import_waitlist/2`). A sheet with month-first dates or missing
  columns is refused as a whole and nothing is written. See
  `Dhc.Waitlist.Import`; in a release use `Dhc.Release.import_waitlist/2`.
  """

  @shortdoc "Imports the Waitlist spreadsheet export (use --dry-run first)"

  use Mix.Task

  alias Dhc.Waitlist.Import

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: [dry_run: :boolean]) do
      {opts, [path], []} -> import!(path, Keyword.get(opts, :dry_run, false))
      _ -> Mix.raise("usage: mix dhc.waitlist.import PATH [--dry-run]")
    end
  end

  defp import!(path, dry_run?) do
    Mix.Task.run("app.start")

    case Dhc.BeginnersWorkshops.import_waitlist(File.read!(path), dry_run: dry_run?) do
      {:ok, report} -> print(report)
      {:error, reason} -> Mix.raise("Waitlist import refused: #{reason}")
    end
  end

  defp print(report) do
    for line <- Import.format_report(report), do: Mix.shell().info(line)
  end
end
