defmodule Dhc.Email.DevMailer do
  @moduledoc """
  Relays non-prod email jobs to the local Mailpit container.

  In production, emails are rendered by Loops from its templates. In dev/test
  we don't have those templates, so each job's payload (recipient, friendly
  template name, data variables) is delivered as plain JSON instead — enough
  to verify who would receive what. Read the messages in the Mailpit web UI
  at `http://localhost:8025` (the `mailpit` service in the root
  `docker-compose.yml`, SMTP on `localhost:1025`).

  Swapped out in tests via the `:email_dev_mailer` app env (see
  `test/support/email_dev_mailer_stub.ex`), mirroring the
  `:discord_oauth_strategy` / `:onboarding_stripe_adapter` seams.

  ## Message format

  A minimal RFC 5322 message built by hand (CRLF line endings, base64 body so
  non-ASCII `data_variables` values stay 7-bit clean) — no `:mimemail`
  involved. Mailpit decodes and displays the JSON body as plain text.
  """

  require Logger

  @default_config [relay: "localhost", port: 1025, from: "dev@dhc.local"]

  @doc """
  Delivers `body` to `to` over SMTP via the configured dev relay.

  Returns `:ok` on delivery, or `{:error, reason}`. Callers decide how to
  react: the email worker logs and swallows failures so a stopped Mailpit
  container never wedges the dev Oban queue.
  """
  def deliver(to, subject, body) when is_binary(to) and is_binary(subject) and is_binary(body) do
    config = smtp_config()
    from = Keyword.fetch!(config, :from)

    message =
      [
        "From: #{from}",
        "To: #{to}",
        "Subject: #{subject}",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: base64",
        "",
        Base.encode64(body)
      ]
      |> Enum.join("\r\n")

    # Mailpit needs no auth or TLS; a short timeout keeps a wedged relay from
    # stalling an Oban worker for the client's long default.
    options = [
      relay: Keyword.fetch!(config, :relay),
      port: Keyword.fetch!(config, :port),
      auth: :never,
      tls: :never,
      timeout: 5_000
    ]

    case :gen_smtp_client.send_blocking({from, [to], message}, options) do
      receipt when is_binary(receipt) ->
        :ok

      {:error, _kind, reason} = error ->
        Logger.warning("[dev-mailer] SMTP delivery failed: #{inspect(reason)}")
        error

      {:error, reason} = error ->
        Logger.warning("[dev-mailer] SMTP delivery failed: #{inspect(reason)}")
        error
    end
  end

  defp smtp_config do
    Application.get_env(:dhc, :dev_smtp, @default_config)
  end
end
