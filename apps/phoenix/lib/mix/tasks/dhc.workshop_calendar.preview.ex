defmodule Mix.Tasks.Dhc.WorkshopCalendar.Preview do
  @shortdoc "Previews upcoming Calendar events and invitation recipients without sending"
  @moduledoc """
  Prints a read-only JSON launch preview. Makes no Google calls or database writes.
  Contains recipient addresses: run only in an authorized operator session and
  treat output as a private operator artifact, not an application log.

      mix dhc.workshop_calendar.preview
  """
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    # Never `app.start`: see `Mix.Dhc.ReadOnlyRepo`.
    Mix.Dhc.ReadOnlyRepo.run(fn ->
      Mix.shell().info(Jason.encode!(Dhc.WorkshopCalendar.preview(), pretty: true))
    end)
  end

  def run(_args), do: Mix.raise("usage: mix dhc.workshop_calendar.preview")
end
