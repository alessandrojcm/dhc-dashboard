defmodule Dhc.Email.Worker do
  @moduledoc """
  Oban worker that sends transactional emails via the Loops API.

  Migrated from the `process-emails` Deno edge function. Each job represents
  a single email (one Oban job per message, replacing the pgmq batch-read
  pattern).

  ## Job args

    * `email` — the recipient email address
    * `transactional_id` — a friendly template name (`"inviteMember"`,
      `"workshopAnnouncement"`, `"workshopRegistration"`,
      `"workshopRegistrationError"`). The worker translates this to the real
      Loops dashboard transactional ID via the `:loops_transactional_ids` app
      env map (mirroring the edge function's env-var lookup).
    * `data_variables` — key-value pairs injected into the email template
      (values must be strings or numbers)

  ## Friendly name → Loops ID translation

  The arg carries a friendly name; Loops wants the dashboard-generated ID
  (e.g. `clfq6dinn000yl70fgwwyp82l`). Translation happens at send time via
  `Application.get_env(:dhc, :loops_transactional_ids)`, a map keyed by
  friendly name. The map is built in `config/runtime.exs` and `config/dev.exs`
  from the `INVITE_MEMBER_TRANSACTIONAL_ID`,
  `WORKSHOP_ANNOUNCEMENT_TRANSACTIONAL_ID`,
  `WORKSHOP_REGISTRATION_TRANSACTIONAL_ID`, and
  `WORKSHOP_REGISTRATION_ERROR_TRANSACTIONAL_ID` env vars.

  Only `workshopRegistration` has a real Loops ID as its fallback default
  (`cmnok76cq02tq0ix92oeoi1kk`). The other three **must** be set in
  production or the worker fails fast with
  `{:error, {:transactional_id_not_configured, friendly_name}}` — it never
  sends the friendly name to Loops (that produces a 404 after 5 retries).

  ## Environment behaviour

    * **dev/test** — skips the HTTP call and logs the payload instead
    * **prod** — POSTs to `https://app.loops.so/api/v1/transactional` using
      the `LOOPS_API_KEY` environment variable

  Oban handles retries with exponential backoff. If the Loops API returns
  a non-2xx response, the job returns `{:error, reason}` and will be retried
  up to `max_attempts` times.

  ## Logging

  Every log line carries the Oban job context (`oban_job_id`, `oban_attempt`,
  `oban_queue`, `oban_worker`) plus `email` and `transactional_id`. The Loops
  request/response is logged at debug level (without the API key) so failures
  can be correlated to a specific job and HTTP exchange.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5

  require Logger

  @transactional_ids ~w(inviteMember workshopAnnouncement workshopRegistration workshopRegistrationError)
  # Default Loops API URL. Overridable via app config for tests.
  defp loops_api_url,
    do: Application.get_env(:dhc, :loops_api_url, "https://app.loops.so/api/v1/transactional")

  @impl Worker
  def perform(%Oban.Job{args: args} = job) do
    ctx = job_log_context(job)

    with :ok <- validate_args(args, ctx),
         :ok <- send_email(args, job, ctx) do
      :ok
    else
      {:error, reason} = error ->
        Logger.error(
          "[email-worker] Job failed: #{format_reason(reason)}",
          Keyword.merge(ctx,
            email: args["email"],
            transactional_id: args["transactional_id"],
            reason: format_reason(reason)
          )
        )

        error
    end
  end

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

        Sentry.capture_message(message,
          level: :error,
          extra: %{
            args: args,
            validation_errors: errors,
            oban_job_id: ctx[:oban_job_id],
            oban_attempt: ctx[:oban_attempt],
            oban_queue: ctx[:oban_queue],
            oban_worker: ctx[:oban_worker]
          }
        )

        {:error, {:validation, errors}}
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

  defp send_email(%{"email" => email, "transactional_id" => transactional_id} = args, job, ctx) do
    if skip_send?() do
      Logger.info(
        "[email-worker] Skipping email send in non-prod environment",
        Keyword.merge(ctx,
          email: email,
          transactional_id: transactional_id,
          data_variables: inspect(args["data_variables"])
        )
      )

      :ok
    else
      with {:ok, loops_id} <- resolve_loops_id(transactional_id, ctx) do
        post_to_loops(args, loops_id, job, ctx)
      end
    end
  end

  defp skip_send?, do: env() != :prod

  defp env do
    Application.get_env(:dhc, :environment, :development)
  end

  defp resolve_loops_id(friendly_name, ctx) do
    # Translation mirrors the edge function's env-var lookup. The map is built
    # in config/runtime.exs / config/dev.exs from *_TRANSACTIONAL_ID env vars.
    # Only workshopRegistration has a real Loops ID as its fallback default;
    # the others must be configured or we fail fast (never send the friendly
    # name to Loops — that produces a 404 after 5 retries).
    map = Application.get_env(:dhc, :loops_transactional_ids, %{})

    case Map.get(map, to_string(friendly_name)) do
      nil ->
        Logger.error(
          "[email-worker] No Loops ID mapped for transactional_id",
          Keyword.merge(ctx, transactional_id: friendly_name)
        )

        Sentry.capture_message("Loops transactional ID not configured",
          level: :error,
          extra: %{
            transactional_id: friendly_name,
            oban_job_id: ctx[:oban_job_id],
            oban_attempt: ctx[:oban_attempt],
            oban_queue: ctx[:oban_queue],
            oban_worker: ctx[:oban_worker]
          }
        )

        {:error, {:transactional_id_not_configured, friendly_name}}

      loops_id when is_binary(loops_id) and loops_id != "" ->
        {:ok, loops_id}

      _ ->
        Logger.error(
          "[email-worker] Loops ID mapping is empty for transactional_id",
          Keyword.merge(ctx, transactional_id: friendly_name)
        )

        {:error, {:transactional_id_not_configured, friendly_name}}
    end
  end

  defp post_to_loops(
         %{"email" => email, "transactional_id" => transactional_id} = args,
         loops_id,
         _job,
         ctx
       ) do
    api_key = loops_api_key()

    if is_nil(api_key) or api_key == "" do
      Logger.error(
        "[email-worker] LOOPS_API_KEY not configured",
        Keyword.merge(ctx, email: email, transactional_id: transactional_id)
      )

      {:error, :api_key_not_configured}
    else
      data_variables = Map.get(args, "data_variables", %{})

      payload = %{
        email: email,
        transactionalId: loops_id,
        dataVariables: data_variables
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      Logger.debug(
        "[email-worker] POST to Loops",
        Keyword.merge(ctx,
          email: email,
          transactional_id: transactional_id,
          loops_id: loops_id,
          loops_url: loops_api_url(),
          data_variables: inspect(data_variables)
        )
      )

      case Req.post(loops_api_url(), json: payload, headers: headers) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          Logger.info(
            "[email-worker] Email sent successfully",
            Keyword.merge(ctx,
              email: email,
              transactional_id: transactional_id,
              loops_id: loops_id,
              loops_status: status
            )
          )

          :ok

        {:ok, %Req.Response{status: status} = response} ->
          Logger.error(
            "[email-worker] Loops API returned #{status}",
            Keyword.merge(ctx,
              email: email,
              transactional_id: transactional_id,
              loops_id: loops_id,
              loops_status: status,
              loops_body: inspect(response.body)
            )
          )

          {:error, {:loops_api, status}}

        {:error, exception} ->
          Logger.error(
            "[email-worker] HTTP request failed: #{inspect(exception)}",
            Keyword.merge(ctx,
              email: email,
              transactional_id: transactional_id,
              loops_id: loops_id,
              http_error: inspect(exception)
            )
          )

          {:error, {:http_error, exception}}
      end
    end
  end

  defp loops_api_key do
    Application.get_env(:dhc, :loops_api_key)
  end

  defp job_log_context(%Oban.Job{} = job) do
    [
      oban_job_id: job.id,
      oban_attempt: job.attempt,
      oban_queue: job.queue,
      oban_worker: job.worker
    ]
  end

  defp format_reason({:transactional_id_not_configured, name}),
    do: "transactional_id #{name} not configured"

  defp format_reason({:loops_api, status}), do: "loops_api #{status}"
  defp format_reason({:validation, errors}), do: "validation: #{Enum.join(errors, ", ")}"
  defp format_reason(other), do: inspect(other)
end
