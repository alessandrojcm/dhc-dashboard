defmodule Mix.Tasks.Dhc.WorkshopCalendar.Activate do
  @shortdoc "Activates Calendar sending, including existing upcoming confirmed places"
  @moduledoc """
  Explicitly enables sending for the configured environment. This can send Google
  invitations to existing confirmed attendees. It re-reads current facts; it does
  not execute a saved preview. Deployment and credentials alone never activate it.

      mix dhc.workshop_calendar.activate isolated
      mix dhc.workshop_calendar.activate production

  The argument must match WORKSHOP_CALENDAR_ENVIRONMENT. Isolated testing must use
  separate credentials/calendars and synthetic recipients, never production data.
  """
  use Mix.Task

  @impl Mix.Task
  def run([target]) when target in ["isolated", "production"] do
    Mix.Task.run("app.start")

    case Dhc.WorkshopCalendar.activate(target) do
      {:ok, result} ->
        Mix.shell().info(
          "Calendar sending activated for #{target}; #{result.sources} upcoming sources queued."
        )

      {:error, reason} ->
        Mix.raise("Calendar activation refused: #{inspect(reason)}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix dhc.workshop_calendar.activate isolated|production")
end
