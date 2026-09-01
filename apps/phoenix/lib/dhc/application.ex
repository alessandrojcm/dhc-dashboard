defmodule Dhc.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Add Sentry logger handler (only takes effect if SENTRY_DSN is configured)
    Logger.add_handlers(:dhc)

    # OpenTelemetry trace propagation and instrumentation
    # Sentry.OpenTelemetry.SpanProcessor turns OTel spans into Sentry transactions/spans.
    OpentelemetryLoggerMetadata.setup()
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:dhc, :repo], db_statement: :enabled)

    children =
      [
        DhcWeb.Telemetry,
        Dhc.Repo,
        {IdempotencyPlug.RequestTracker,
         name: DhcWeb.IdempotencyRequestTracker,
         store: {IdempotencyPlug.EctoStore, repo: Dhc.Repo}},
        {DNSCluster, query: Application.get_env(:dhc, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Dhc.PubSub},
        # HTTP pool for the Swoosh email transport (ADR 0021). The name must
        # match config :swoosh, :finch_name.
        {Finch, name: Swoosh.Finch},
        # Oban for background job processing
        {Oban, Application.fetch_env!(:dhc, Oban)},
        Dhc.Discord.GuildMemberCache
      ] ++
        discord_children() ++
        [
          # Start to serve requests, typically the last entry
          DhcWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Dhc.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp discord_children do
    case Application.get_env(:dhc, :discord_bot_token) do
      token when is_binary(token) and byte_size(token) > 0 ->
        [{Dhc.Discord.RestClientSupervisor, token: token}]

      _missing ->
        []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DhcWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
