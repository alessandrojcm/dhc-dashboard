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
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("E2E_API_PORT", "4002"))],
  # WebSocket origin validation for the Notification socket. Tests don't upgrade
  # a real transport, but the value is kept consistent with the CORS allow-list
  # so the endpoint reflects production-shaped configuration.
  check_origin: ["http://localhost:5173"],
  secret_key_base: "4NYsNq71KJ4FMFOGvvddgFNTCbmuHANzkI6ZFu7ShIV+LhLwwdeG+iyDS7BEIW0t",
  server: System.get_env("E2E_SERVER") == "true"

# Configure Oban for testing
config :dhc, Oban,
  repo: Dhc.Repo,
  testing: :manual,
  plugins: false,
  queues: false

# Discord worker — skip sending in test
config :dhc, :discord_webhook_url, "https://discord.example.com/webhook/test"
# Email worker — dev delivery goes to the stub (never a real SMTP relay);
# the Loops API path is exercised by the prod-env describe block via Bypass.
config :dhc, :email_dev_mailer, Dhc.Email.DevMailerStub
config :dhc, :loops_api_key, "test-loops-api-key"
# Friendly name -> real Loops transactional ID mapping (test stubs).
# The worker resolves this in prod-env tests (the describe block that flips
# :environment to :prod and hits Bypass). Test env proper skips the send
# before resolving, so these stubs only matter for the prod-env tests.
config :dhc, :loops_transactional_ids, %{
  "inviteMember" => "test-loops-id-inviteMember",
  "workshopAnnouncement" => "test-loops-id-workshopAnnouncement",
  "workshopRegistration" => "test-loops-id-workshopRegistration",
  "workshopRegistrationError" => "test-loops-id-workshopRegistrationError",
  "magicLink" => "test-loops-id-magicLink"
}

# Tests that exercise Stripe replace the client or use test-mode credentials.
e2e_server? = System.get_env("E2E_SERVER") == "true"
stripe_secret_key = System.get_env("STRIPE_SECRET_KEY")

if e2e_server? and
     (is_nil(stripe_secret_key) or not String.starts_with?(stripe_secret_key, "sk_test_")) do
  raise "E2E_SERVER requires a non-empty Stripe test-mode STRIPE_SECRET_KEY (sk_test_...)"
end

config :dhc, :stripe_secret_key, stripe_secret_key || "sk_test_stub_key"
config :dhc, :stripe_api_url, System.get_env("STRIPE_API_URL", "https://api.stripe.com")
config :dhc, :stripe_api_version, "2025-10-29.clover"
config :dhc, :stripe_webhook_secret, "whsec_test_signing_key_for_webhook_verification"
config :dhc, :invitation_verification_token_salt, "invitation-verification-test"

config :dhc,
       :invitation_acceptance_subject_fingerprint_secret,
       "acceptance-subject-fingerprint-test"

config :dhc, :supabase_url, "https://supabase.example.com"
config :dhc, :supabase_service_role_key, "test-service-role-key"
app_url = System.get_env("APP_URL", "http://localhost:5173")
config :dhc, :app_url, app_url

config :dhc,
       :invitation_acceptance_discord_redirect_uri,
       "#{app_url}/auth/discord/acceptance/callback"

config :dhc, :auth_session_domain, nil
config :dhc, :auth_session_secure, false
config :dhc, :environment, :test

config :dhc, :cors_allowed_origins, [
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "https://127.0.0.1:5173"
]

config :dhc, :e2e_harness, System.get_env("E2E_SERVER") == "true"
config :dhc, :e2e_harness_key, System.get_env("E2E_HARNESS_KEY", "local-e2e-harness")
config :dhc, :discord_oauth_strategy, Dhc.DiscordOAuthStub
config :dhc, :discord_oauth, client_id: "test-client", client_secret: "test-secret"
config :dhc, :discord_subject_fingerprint_key, "test-discord-subject-fingerprint-key"

if e2e_server? do
  config :dhc, :onboarding_stripe_adapter, Dhc.Onboarding.StripeAdapter.Live
  config :dhc, :onboarding_finalizer, Dhc.E2EOnboardingFinalizer
  config :dhc, :acceptance_recovery_delay_seconds, 1

  config :dhc, Oban,
    repo: Dhc.Repo,
    testing: :disabled,
    plugins: [],
    queues: [invitations: 1, stripe: 1]
end

# Keep normal test output quiet, but expose Phoenix request and application logs
# when Playwright owns the E2E server lifecycle.
config :logger, level: if(e2e_server?, do: :info, else: :warning)

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
