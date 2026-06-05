import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dhc, Dhc.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 54322,
  database: "postgres",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dhc, DhcWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "4NYsNq71KJ4FMFOGvvddgFNTCbmuHANzkI6ZFu7ShIV+LhLwwdeG+iyDS7BEIW0t",
  server: false

# Configure Oban for testing
config :dhc, Oban,
  repo: Dhc.Repo,
  testing: :manual,
  plugins: false,
  queues: false

# Discord worker — skip sending in test
config :dhc, :discord_webhook_url, "https://discord.example.com/webhook/test"
# Email worker — skip sending in test
config :dhc, :loops_api_key, "test-loops-api-key"
# Stripe sync — skip API calls in test
config :dhc, :stripe_secret_key, "sk_test_stub_key"
config :dhc, :stripe_api_url, "https://stripe.example.com"
config :dhc, :stripe_api_version, "2025-10-29.clover"
config :dhc, :stripe_webhook_secret, "whsec_test_signing_key_for_webhook_verification"
config :dhc, :environment, :test

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
