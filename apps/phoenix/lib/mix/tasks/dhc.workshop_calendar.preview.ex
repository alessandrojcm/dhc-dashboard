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
    # Load runtime configuration (including the configured Repo) without
    # starting :dhc and therefore without starting Oban or the endpoint.
    Mix.Task.run("app.config")

    with_repo(fn ->
      Mix.shell().info(Jason.encode!(Dhc.WorkshopCalendar.preview(), pretty: true))
    end)
  end

  def run(_args), do: Mix.raise("usage: mix dhc.workshop_calendar.preview")

  # This task must not start :dhc: its supervision tree includes Oban and the
  # endpoint, either of which could perform work while an operator expects a
  # read-only preview. A cold Mix VM gets only the SQL applications and a
  # temporary Repo. Keep a caller-owned Repo (notably the test application)
  # running untouched.
  defp with_repo(fun) do
    if Process.whereis(Dhc.Repo) do
      fun.()
    else
      Application.ensure_all_started(:ecto_sql)
      Application.ensure_all_started(:postgrex)

      config = Application.fetch_env!(:dhc, Dhc.Repo) |> Keyword.delete(:pool)

      {:ok, supervisor} =
        Supervisor.start_link([{Dhc.Repo, config}], strategy: :one_for_one)

      try do
        fun.()
      after
        :ok = Supervisor.stop(supervisor)
      end
    end
  end
end
