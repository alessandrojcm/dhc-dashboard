defmodule Mix.Tasks.Dhc.BeginnersWorkshops.EndTimes do
  @shortdoc "Reports upcoming Beginners' Workshops missing a valid end time"
  @moduledoc """
  Lists upcoming scheduled Beginners' Workshops whose explicit Dublin civil end
  time is missing or invalid. The task is read-only and does not contact
  Google.

      mix dhc.beginners_workshops.end_times
  """

  use Mix.Task

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.start")

    case Dhc.BeginnersWorkshops.end_time_report() do
      [] -> Mix.shell().info("Every upcoming Beginners' Workshop has a valid end time.")
      rows -> Enum.each(rows, &print/1)
    end
  end

  def run(_args), do: Mix.raise("usage: mix dhc.beginners_workshops.end_times")

  defp print(row) do
    Mix.shell().info(
      "#{row.issue}: #{row.id} #{Date.to_iso8601(row.date)} " <>
        "#{Calendar.strftime(row.start_time, "%H:%M")}–#{format_end_time(row.end_time)}"
    )
  end

  defp format_end_time(nil), do: "unknown"
  defp format_end_time(time), do: Calendar.strftime(time, "%H:%M")
end
