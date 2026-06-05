# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dhc,
  ecto_repos: [Dhc.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure Oban for background job processing
config :dhc, Oban,
  repo: Dhc.Repo,
  prefix: "public",
  queues: [default: 10, emails: 5, discord: 5, announcements: 5, stripe: 5, invitations: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    Oban.Plugins.Lifeline,
    {Oban.Plugins.Reindexer, schedule: "@weekly"},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 0 * * *", Dhc.StripeSync.Worker}
     ]}
  ]

# Configure the endpoint
config :dhc, DhcWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: DhcWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Dhc.PubSub,
  live_view: [signing_salt: "waaLZGuC"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Stripe API — pinned to match the version used by the Deno edge functions
# and the generated OpenAPI client. Update this + re-run `mise run stripe-gen`
# when Stripe releases a new API version.
config :dhc, :stripe_api_version, "2025-10-29.clover"

# OpenAPI code generator profile for Stripe (dev-only dependency).
# Used by `mix api.gen stripe` (triggered via `mise run stripe-gen`).
# The processor filters to only the operations we need.
# When Stripe updates their API, re-run `mise run stripe-gen` to regenerate.
config :oapi_generator,
  stripe: [
    processor: Dhc.Stripe.Processor,
    ignore: [:deprecated],
    output: [
      base_module: Dhc.Stripe,
      location: "lib/dhc/stripe/generated",
      default_client: Dhc.Stripe.Client,
      field_casing: :snake
    ]
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
