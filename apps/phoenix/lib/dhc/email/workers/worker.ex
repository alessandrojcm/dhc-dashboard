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
      `"workshopRegistrationError"`, `"magicLink"`, `"beginnersWorkshopAction"`,
      `"beginnersWorkshopNotice"`). The worker derives the Resend template
      alias mechanically in kebab-case.
    * `subject` (optional) — a non-blank string that overrides the
      template's default subject. Intake Emails (ALE-377) pass the subject
      filled from the club-wide template when they are queued.
    * `data_variables` — key-value pairs injected into the email template
      (values must be strings or numbers)
    * `sealed_data_variables` (optional) — more template variables, encrypted
      with `seal_data_variables/1`. Use it for any value that is a credential
      (the magic-link `LOGIN_LINK` carries a live login token): job args are
      stored in `oban_jobs` until pruned and attached to Sentry events by the
      Oban integration, so a plaintext credential there would outlive the
      email. The ciphertext is bound to `secret_key_base` and expires after
      a Kind-dependent lifetime: 15 minutes by default (the magic-link token
      lives that long), 24 hours for the Beginners' Workshop Kinds, whose
      Intake link stays valid while the Intake is open, so a worker outage
      must not silently drop the email. An expired or tampered value cancels
      the job.
      Sealed variables override plain ones with the same key.

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
  failures can be correlated to a specific job. Data variable **values** are
  never logged or sent to Sentry — only their keys.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5

  require Logger

  alias Dhc.Email.Mailer
  alias Swoosh.Email

  @transactional_ids ~w(inviteMember workshopAnnouncement workshopRegistration workshopRegistrationError magicLink beginnersWorkshopAction beginnersWorkshopNotice)
  @idempotency_header "Idempotency-Key"

  # The magic-link token is valid for 15 minutes; a sealed value older than
  # that could only deliver a dead link. Intake links stay valid while the
  # Intake is open, so their Kinds keep the seal for a day instead.
  @sealed_max_age_seconds 15 * 60
  @sealed_max_age_seconds_by_kind %{
    "beginnersWorkshopAction" => 24 * 60 * 60,
    "beginnersWorkshopNotice" => 24 * 60 * 60
  }
  @sealed_salt "dhc.email.worker sealed_data_variables v1"

  @doc """
  Encrypts template variables for the `sealed_data_variables` job arg.

  Values must be strings or numbers, like `data_variables`.
  """
  @spec seal_data_variables(%{optional(String.t()) => String.t() | number()}) :: String.t()
  def seal_data_variables(variables) when is_map(variables) do
    Plug.Crypto.encrypt(secret_key_base(), @sealed_salt, variables)
  end

  @impl Worker
  def perform(%Oban.Job{args: args} = job) do
    ctx = job_log_context(job)

    with :ok <- validate_args(args, ctx),
         {:ok, args} <- unseal_data_variables(args, ctx),
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
      |> validate_sealed_data_variables(args)
      |> validate_subject(args)

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
          args: redact_args(args),
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

  defp validate_sealed_data_variables(errors, %{"sealed_data_variables" => sealed})
       when not is_nil(sealed) and not is_binary(sealed),
       do: ["sealed_data_variables must be a string" | errors]

  defp validate_sealed_data_variables(errors, _args), do: errors

  defp validate_subject(errors, %{"subject" => subject}) do
    if is_binary(subject) and String.trim(subject) != "" do
      errors
    else
      ["subject must be a non-blank string" | errors]
    end
  end

  defp validate_subject(errors, _args), do: errors

  # -- Sealed data variables ---------------------------------------------------

  defp unseal_data_variables(%{"sealed_data_variables" => sealed} = args, ctx)
       when is_binary(sealed) do
    case Plug.Crypto.decrypt(secret_key_base(), @sealed_salt, sealed,
           max_age: sealed_max_age_seconds(args["transactional_id"])
         ) do
      {:ok, variables} when is_map(variables) ->
        if valid_variable_values?(variables) do
          plain = Map.get(args, "data_variables", %{})
          {:ok, Map.put(args, "data_variables", Map.merge(plain, variables))}
        else
          cancel_unsealable(args, :invalid_values, ctx)
        end

      {:ok, _other} ->
        cancel_unsealable(args, :invalid_values, ctx)

      {:error, reason} ->
        cancel_unsealable(args, reason, ctx)
    end
  end

  defp unseal_data_variables(args, _ctx), do: {:ok, args}

  defp sealed_max_age_seconds(kind),
    do: Map.get(@sealed_max_age_seconds_by_kind, kind, @sealed_max_age_seconds)

  # An expired or tampered value cannot be fixed by retrying. The reason is
  # `:expired`, `:invalid` or `:invalid_values`; never the ciphertext.
  defp cancel_unsealable(args, reason, ctx) do
    message = "Could not unseal email data variables (#{reason})"

    Logger.error(
      "[email-worker] #{message}",
      Keyword.merge(ctx, email: args["email"], transactional_id: args["transactional_id"])
    )

    capture_deterministic_failure(message, ctx, args: redact_args(args))
    {:cancel, {:sealed_data_variables, reason}}
  end

  defp valid_variable_values?(variables) do
    Enum.all?(variables, fn
      {key, value} when is_binary(key) -> is_binary(value) or is_number(value)
      _ -> false
    end)
  end

  # What may leave the worker about a job's args: the recipient and kind, plus
  # the *names* of its template variables. Values (which can carry links,
  # names, or credentials) and ciphertext never do.
  defp redact_args(args) when is_map(args) do
    %{
      email: args["email"],
      transactional_id: args["transactional_id"],
      data_variable_keys: variable_keys(args["data_variables"]),
      sealed_data_variables: Map.has_key?(args, "sealed_data_variables")
    }
  end

  defp variable_keys(vars) when is_map(vars), do: vars |> Map.keys() |> Enum.map(&to_string/1)
  defp variable_keys(_vars), do: []

  # -- Delivery ----------------------------------------------------------------

  defp deliver(
         %{"email" => recipient, "transactional_id" => kind} = args,
         %Oban.Job{} = job,
         ctx
       ) do
    data_variables = Map.get(args, "data_variables", %{})

    recipient
    |> build_email(kind, data_variables, args["subject"], job.id)
    |> deliver_email(kind, ctx)
  end

  defp build_email(recipient, kind, data_variables, subject, oban_job_id) do
    email =
      Email.new()
      |> Email.from(email_from())
      |> Email.reply_to(email_reply_to())
      |> Email.to(recipient)
      |> Email.put_provider_option(:template, %{
        id: template_alias(kind),
        variables: data_variables
      })
      |> put_subject(subject)

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
    |> decorate_for_dev(recipient, kind, data_variables, subject)
  end

  # Resend uses the template's default subject unless the payload sets one.
  defp put_subject(email, nil), do: email
  defp put_subject(email, subject), do: Email.subject(email, subject)

  # Non-prod only: providers render real bodies from their templates, so the
  # dev inbox gets a JSON summary (recipient + friendly Kind + variables).
  defp decorate_for_dev(email, recipient, kind, data_variables, subject_override) do
    if env() == :prod do
      email
    else
      summary = %{email: recipient, transactional_id: kind, data_variables: data_variables}

      {payload, subject} =
        case subject_override do
          nil -> {summary, "[dev] Email: #{kind}"}
          override -> {Map.put(summary, :subject, override), "[dev] #{override}"}
        end

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

  defp secret_key_base, do: DhcWeb.Endpoint.config(:secret_key_base)

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

  defp email_reply_to do
    Application.get_env(:dhc, :email_reply_to, "contact@dublinhemaclub.com")
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
