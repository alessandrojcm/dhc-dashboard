import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
#
# hostname + port set dynamically by test_helper.exs from the compose
# environment (testcontainers-elixir allocates a dynamic host port per run;
# test_helper.exs reads it via ComposeEnvironment.get_service_port/3 and
# merges it into this config before the app starts). See ADR 0006.
#
# username/password/database are read from the same .env that interpolates the
# root docker-compose.yml `db` service (loaded by mise via [env] _.file = ".env"
# and by the compose file's ${POSTGRES_PASSWORD}/${POSTGRES_DB}). Defaults match
# the old hardcoded values so a bare `mix test` without .env still works.
config :dhc, Dhc.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  database: System.get_env("POSTGRES_DB", "postgres"),
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
# Friendly name -> real Loops transactional ID mapping (test stubs).
# The worker resolves this in prod-env tests (the describe block that flips
# :environment to :prod and hits Bypass). Test env proper skips the send
# before resolving, so these stubs only matter for the prod-env tests.
config :dhc, :loops_transactional_ids, %{
  "inviteMember" => "test-loops-id-inviteMember",
  "workshopAnnouncement" => "test-loops-id-workshopAnnouncement",
  "workshopRegistration" => "test-loops-id-workshopRegistration",
  "workshopRegistrationError" => "test-loops-id-workshopRegistrationError"
}

# Stripe sync — skip API calls in test
config :dhc, :stripe_secret_key, "sk_test_stub_key"
config :dhc, :stripe_api_url, "https://stripe.example.com"
config :dhc, :stripe_api_version, "2025-10-29.clover"
config :dhc, :stripe_webhook_secret, "whsec_test_signing_key_for_webhook_verification"
config :dhc, :supabase_url, "https://supabase.example.com"
config :dhc, :supabase_service_role_key, "test-service-role-key"
config :dhc, :app_url, "http://localhost:5173"
config :dhc, :environment, :test
config :dhc, :cors_allowed_origins, ["http://localhost:5173"]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
