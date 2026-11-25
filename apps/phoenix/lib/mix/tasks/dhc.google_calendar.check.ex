defmodule Mix.Tasks.Dhc.GoogleCalendar.Check do
  @shortdoc "Checks the loaded Google Calendar connection and targets without sending"
  @moduledoc """
  Prints secret-safe JSON and fails if the connection or a target needs repair.
  Starts only runtime configuration and Req, never Dhc, Oban, or Repo.

      mix dhc.google_calendar.check

  This checks this Mix process's configuration. To check the running release
  after rotating credentials and restarting, use:

      bin/dhc rpc 'IO.inspect(Dhc.GoogleCalendar.check())'
  """
  use Mix.Task

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req)
    report = Dhc.GoogleCalendar.check()
    Mix.shell().info(Jason.encode!(report, pretty: true))

    unless report.authentication == :ok and
             Enum.all?(report.calendars, fn {_target, status} ->
               status == :ok
             end) do
      Mix.raise("Google Calendar check failed; see the safe report above.")
    end
  end

  def run(_args), do: Mix.raise("usage: mix dhc.google_calendar.check")
end
