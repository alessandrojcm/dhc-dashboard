defmodule Mix.Dhc.ReadOnlyRepo do
  @moduledoc """
  Runs a read-only operator task against the configured Repo without starting
  `:dhc`.

  The application's supervision tree includes Oban and the endpoint, either of
  which could perform work while an operator expects a read-only preview. A
  cold Mix VM gets only `app.config`, the SQL applications and a temporary
  Repo; a caller-owned Repo (notably the test application) is used untouched.
  """

  @doc "Loads runtime configuration and runs `fun` with a Repo available."
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    # Load runtime configuration (including the configured Repo) without
    # starting :dhc and therefore without starting Oban or the endpoint.
    Mix.Task.run("app.config")

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
