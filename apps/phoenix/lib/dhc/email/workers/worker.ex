defmodule Dhc.Email.Worker do
  @moduledoc """
  Oban worker that sends transactional emails through the Swoosh transport
  seam (ADR 0021 — Swoosh Is the Email Transport Seam).

  Migrated from the `process-emails` Deno edge function. Each job represents
  a single email (one Oban job per message, replacing the pgmq batch-read
  pattern).

  ## Job args (public contract — unchanged)

    * `email` — the recipient email address
    * `transactional_id` — the Email Kind (`"inviteMember"`,
      `"workshopAnnouncement"`, `"workshopRegistration"`,
      `"workshopRegistrationError"`, `"magicLink"`). The worker derives the
      Resend template alias mechanically in kebab-case.
    * `data_variables` — key-value pairs injected into the email template
      (values must be strings or numbers)

  ## Delivery

  The worker builds one `%Swoosh.Email{}` per job — recipient, sender, and
  Resend template option — and hands it to `Dhc.Email.Mailer`. The configured
  adapters are `Swoosh.Adapters.Resend` in prod, `Swoosh.Adapters.Mailpit`
  over HTTP in dev (`http://localhost:8025` web UI), and
  `Swoosh.Adapters.Test` in tests.

  Outside prod the message is decorated with a JSON summary body
  (recipient + friendly Kind + data variables) so the dev inbox shows who
  would receive what; providers render real bodies from their templates.

  ## Idempotency

  Every send carries an `Idempotency-Key` derived from the Oban job id
  (`oban-<job.id>`), applied at the HTTP layer by `Dhc.Email.ApiClient`.
  Provider retries therefore cannot double-send a delivered email.

  ## Error classification

    * Invalid job args are deterministic: the job is **cancelled
      immediately** (`{:cancel, _}`) with a Sentry capture instead of burning
      five identical attempts.
    * In prod, provider responses of 4xx (except 429 rate limiting) are
      deterministic rejections too: cancelled with Sentry capture. Rate
      limits, 5xx, and network errors are transient: returned as
      `{:error, reason}` for Oban's exponential-backoff retries
      (`max_attempts: 5`).
    * Outside prod, delivery failures are logged and swallowed (`:ok`) —
      a stopped Mailpit container must never fail or retry dev jobs.

  ## Logging

  Every log line carries the Oban job context (`oban_job_id`, `oban_attempt`,
  `oban_queue`, `oban_worker`) plus `email` and `transactional_id`, so
  failures can be correlated to a specific job.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5

  require Logger

  alias Dhc.Email.Mailer
  alias Swoosh.Email

  @transactional_ids ~w(inviteMember workshopAnnouncement workshopRegistration workshopRegistrationError magicLink)
  @idempotency_header "Idempotency-Key"

  @impl Worker
  def perform(%Oban.Job{args: args} = job) do
    ctx = job_log_context(job)

    with :ok <- validate_args(args, ctx),
         :ok <- deliver(args, job, ctx) do
      :ok
    else
      {:cancel, _reason} = cancelled -> cancelled
      {:error, _reason} = retryable -> retryable
    end
  end

  # -- Argument validation ----------------------------------------------------

  defp validate_args(args, ctx) do
    errors =
      []
      |> validate_required(args, "email")
      |> validate_email_format(args)
      |> validate_required(args, "transactional_id")
      |> validate_transactional_id(args)
      |> validate_data_variables(args)

    case errors do
      [] ->
        :ok

      errors ->
        message = "Invalid email job args: #{Enum.join(errors, ", ")}"

        Logger.error(
          "[email-worker] #{message}",
          Keyword.merge(ctx,
            email: args["email"],
            transactional_id: args["transactional_id"],
            validation_errors: Enum.join(errors, ", ")
          )
        )

        capture_deterministic_failure(message, ctx,
          args: args,
          validation_errors: errors
        )

        {:cancel, {:validation, errors}}
    end
  end

  defp validate_required(errors, args, field) do
    if is_nil(args[field]) or args[field] == "" do
      ["missing #{field}" | errors]
    else
      errors
    end
  end

  defp validate_email_format(errors, %{"email" => email}) when is_binary(email) do
    if email =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/ do
      errors
    else
      ["invalid email format" | errors]
    end
  end

  defp validate_email_format(errors, _args), do: errors

  defp validate_transactional_id(errors, %{"transactional_id" => id})
       when id in @transactional_ids,
       do: errors

  defp validate_transactional_id(errors, _args),
    do: ["invalid transactional_id" | errors]

  defp validate_data_variables(errors, %{"data_variables" => vars}) when is_map(vars) do
    invalid_values =
      Enum.any?(vars, fn
        {_k, v} when is_binary(v) -> false
        {_k, v} when is_number(v) -> false
        _ -> true
      end)

    if invalid_values do
      ["data_variables values must be strings or numbers" | errors]
    else
      errors
    end
  end

  defp validate_data_variables(errors, _args), do: errors

  # -- Delivery ----------------------------------------------------------------

  defp deliver(
         %{"email" => recipient, "transactional_id" => kind} = args,
         %Oban.Job{} = job,
         ctx
       ) do
    data_variables = Map.get(args, "data_variables", %{})

    recipient
    |> build_email(kind, data_variables, job.id)
    |> deliver_email(kind, ctx)
  end

  defp build_email(recipient, kind, data_variables, oban_job_id) do
    email =
      Email.new()
      |> Email.from(email_from())
      |> Email.to(recipient)
      |> Email.put_provider_option(:template, %{
        id: template_alias(kind),
        variables: data_variables
      })

    if oban_job_id do
      key = "oban-#{oban_job_id}"

      email
      |> Email.put_provider_option(:idempotency_key, key)
      # MIME-level copy for dev-inbox observability; the wire header comes from
      # the provider option via Dhc.Email.ApiClient.
      |> Email.header(@idempotency_header, key)
    else
      email
    end
    |> decorate_for_dev(recipient, kind, data_variables)
  end

  # Non-prod only: providers render real bodies from their templates, so the
  # dev inbox gets a JSON summary (recipient + friendly Kind + variables).
  defp decorate_for_dev(email, recipient, kind, data_variables) do
    if env() == :prod do
      email
    else
      payload = %{
        email: recipient,
        transactional_id: kind,
        data_variables: data_variables
      }

      subject = "[dev] Email: #{kind}"
      body = Jason.encode!(payload, pretty: true)

      email
      |> Email.subject(subject)
      |> Email.text_body(body)
    end
  end

  defp deliver_email(%Email{} = email, kind, ctx) do
    case Mailer.deliver(email) do
      {:ok, receipt} ->
        Logger.info(
          "[email-worker] Email sent successfully",
          Keyword.merge(ctx,
            email: recipient_address(email),
            transactional_id: kind,
            receipt: inspect(receipt)
          )
        )

        :ok

      {:error, reason} ->
        handle_delivery_error(reason, kind, ctx)
    end
  end

  defp handle_delivery_error(reason, kind, ctx) do
    if env() == :prod do
      classify_delivery_error(reason, kind, ctx)
    else
      Logger.warning(
        "[email-worker] Dev relay delivery failed (is `docker compose up -d mailpit` running?), job will not retry",
        Keyword.merge(ctx,
          transactional_id: kind,
          reason: inspect(reason)
        )
      )

      :ok
    end
  end

  # Deterministic rejections (4xx except rate limiting): retrying cannot fix a
  # bad payload or template mapping, so cancel immediately with a Sentry
  # capture rather than burn all attempts.
  defp classify_delivery_error({status, _body}, kind, ctx)
       when is_integer(status) and status >= 400 and status < 500 and status != 429 do
    message = "Provider rejected #{kind}; discarding job"

    Logger.error(
      "[email-worker] #{message}",
      Keyword.merge(ctx,
        transactional_id: kind,
        provider_status: status
      )
    )

    capture_deterministic_failure(message, ctx,
      transactional_id: kind,
      provider_status: status
    )

    {:cancel, {:provider_rejected, status}}
  end

  # Rate limits (429), 5xx, and network errors are transient — let Oban retry
  # with backoff. The Idempotency-Key makes those retries safe against
  # double-sends that were already accepted.
  defp classify_delivery_error(reason, kind, ctx) do
    Logger.error(
      "[email-worker] Transient delivery failure; Oban will retry",
      Keyword.merge(ctx,
        transactional_id: kind,
        reason: inspect(reason)
      )
    )

    {:error, reason}
  end

  # -- Environment & helpers ---------------------------------------------------

  defp env do
    Application.get_env(:dhc, :environment, :development)
  end

  defp template_alias(kind) do
    ~r/([a-z0-9])([A-Z])/
    |> Regex.replace(kind, "\\1-\\2")
    |> String.downcase()
  end

  # Sentry capture for deterministic failures (invalid args, unmapped template
  # IDs, provider rejections). Oban context rides in :extra as a flat map —
  # this Sentry version does not accept :contexts.
  defp capture_deterministic_failure(message, ctx, extra) do
    Sentry.capture_message(message,
      level: :error,
      extra:
        Map.merge(Map.new(extra), %{
          oban_job_id: ctx[:oban_job_id],
          oban_attempt: ctx[:oban_attempt],
          oban_queue: ctx[:oban_queue],
          oban_worker: ctx[:oban_worker]
        })
    )
  end

  # Swoosh requires a sender on every message. Resend templates define the
  # production sender; Mailpit shows this fallback in the dev inbox.
  defp email_from do
    Application.get_env(:dhc, :email_from, "dev@dhc.local")
  end

  defp recipient_address(%Email{to: [{_, recipient}]}) when is_binary(recipient),
    do: recipient

  defp recipient_address(%Email{to: to}), do: inspect(to)

  defp job_log_context(%Oban.Job{} = job) do
    [
      oban_job_id: job.id,
      oban_attempt: job.attempt,
      oban_queue: job.queue,
      oban_worker: job.worker
    ]
  end
end
