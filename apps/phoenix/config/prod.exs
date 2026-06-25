import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :dhc, DhcWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # Fly.io performs internal HTTP checks against this route on PORT.
      # Do not redirect it to HTTPS, otherwise Fly marks the Machine unhealthy.
      paths: ["/api/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

config :sentry,
  dsn:
    "https://7c84fc19bc35624e3ff99ecefa7a8b9c@o4509135535079424.ingest.de.sentry.io/4511571585597520",
  environment_name: Mix.env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
