defmodule Dhc.MixProject do
  use Mix.Project

  def project do
    [
      app: :dhc,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Dhc.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:oban, "~> 2.19"},
      {:sentry, "~> 13.0"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_logger_metadata, "~> 0.2"},
      {:supabase_potion, "~> 0.7"},
      {:supabase_auth, "~> 1.0"},
      {:hackney, "~> 1.8"},
      {:finch, "~> 0.22.0"},
      {:req, "~> 0.5"},
      # Fakerer: maintained fork of elixirs/faker. OTP app stays `:faker`,
      # Hex package is `:fakerer`. Dev-only (used by seeding mix tasks).
      # NOT `runtime: false`: seed tasks call `Mix.Task.run("app.start")`,
      # which starts :faker + its transitive dep :makeup automatically.
      {:faker, "~> 1.0", hex: :fakerer, only: :dev},
      # Mix tasks live under lib/mix/tasks and are compiled as part of releases.
      # Keep their compile-time dependencies available in prod, but out of the
      # runtime application list.
      {:yaml_elixir, "~> 2.11", runtime: false},
      {:open_api_spex, "~> 3.22", runtime: false},
      {:oapi_generator, "~> 0.4.0", only: :dev, runtime: false},
      # Bypass must be present in test for HTTP stubbing; --no-start in the
      # test alias disables its autostart, so test_helper.exs starts it
      # explicitly via Application.ensure_all_started(:bypass) before any
      # Bypass.open() call. See ADR 0006.
      {:bypass, "~> 2.1", only: :test},
      # testcontainers-elixir drives the Docker Compose test harness. The
      # compose module (Testcontainers.DockerCompose +
      # Testcontainers.Compose.ComposeEnvironment) landed in 2.3.x (PR #247).
      # See ADR 0006 for the lifecycle: test_helper.exs starts the db profile,
      # reads the dynamic port, then starts the app + runs migrations.
      {:testcontainers, "~> 2.3", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # --no-start is the critical seam for the testcontainers harness: it
      # stops Mix from auto-starting :dhc (and :bypass) before test_helper.exs
      # runs, so test_helper.exs can start compose, read the dynamic DB port,
      # and put_env it BEFORE Application.ensure_all_started(:dhc) starts the
      # Repo. ecto.create/ecto.migrate are deliberately NOT in the test alias
      # — test_helper.exs owns the full compose→migrate→sandbox lifecycle now
      # (ADR 0006). `mix test path/to/file.exs` still routes through here.
      test: ["test --no-start"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
