defmodule Mix.Tasks.E2e.Server do
  use Mix.Task

  @shortdoc "Starts Phoenix against a disposable Testcontainers E2E database"

  @impl Mix.Task
  def run(_args) do
    Application.ensure_all_started(:hackney)
    {:ok, _} = Testcontainers.start_link()

    compose_config =
      Testcontainers.DockerCompose.new("../..")
      |> Testcontainers.DockerCompose.with_project_name(
        System.get_env("E2E_COMPOSE_PROJECT", "dhc-dashboard-e2e")
      )
      |> Testcontainers.DockerCompose.with_profile("testing")
      |> Testcontainers.DockerCompose.with_services(["test-db"])

    {:ok, env} = Testcontainers.start_compose(compose_config)
    port = Testcontainers.Compose.ComposeEnvironment.get_service_port(env, "test-db", 5432)

    if is_nil(port), do: Mix.raise("test-db did not expose PostgreSQL port 5432")

    repo_config =
      Application.get_env(:dhc, Dhc.Repo, [])
      |> Keyword.merge(hostname: "localhost", port: port)
      |> Keyword.delete(:pool)

    Application.put_env(:dhc, Dhc.Repo, repo_config)
    Application.put_env(:dhc, DhcWeb.Endpoint, endpoint_config())
    Application.put_env(:dhc, :onboarding_stripe_adapter, Dhc.OnboardingE2EStripeAdapter)

    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:postgrex)

    {:ok, migration_sup} =
      Supervisor.start_link(
        [{Dhc.Repo, repo_config}],
        strategy: :one_for_one,
        name: Dhc.E2EMigrationSupervisor
      )

    Ecto.Migrator.run(Dhc.Repo, "priv/repo/migrations", :up, all: true)
    :ok = Supervisor.stop(migration_sup)

    System.at_exit(fn _ ->
      Application.stop(:dhc)

      try do
        Testcontainers.stop_compose(env)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, _} = Application.ensure_all_started(:dhc)
    Mix.shell().info("Phoenix E2E API ready on http://127.0.0.1:#{port_from_endpoint()}")
    Process.sleep(:infinity)
  end

  defp endpoint_config do
    Application.get_env(:dhc, DhcWeb.Endpoint, [])
    |> Keyword.put(:server, true)
  end

  defp port_from_endpoint do
    Application.get_env(:dhc, DhcWeb.Endpoint, [])
    |> Keyword.fetch!(:http)
    |> Keyword.fetch!(:port)
  end
end
