defmodule Dhc.Email.Worker do
  @moduledoc """
  Oban worker that sends transactional emails via the Loops API.

  Migrated from the `process-emails` Deno edge function. Each job represents
  a single email (one Oban job per message, replacing the pgmq batch-read
  pattern).

  ## Job args

    * `email` — the recipient email address
    * `transactional_id` — Loops transactional email ID (e.g. `"inviteMember"`,
      `"workshopAnnouncement"`)
    * `data_variables` — key-value pairs injected into the email template
      (values must be strings or numbers)

  ## Environment behaviour

    * **dev/test** — skips the HTTP call and logs the payload instead
    * **prod** — POSTs to `https://app.loops.so/api/v1/transactional` using
      the `LOOPS_API_KEY` environment variable

  Oban handles retries with exponential backoff. If the Loops API returns
  a non-2xx response, the job returns `{:error, reason}` and will be retried
  up to `max_attempts` times.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5

  require Logger

  @transactional_ids ~w(inviteMember workshopAnnouncement)
  # Default Loops API URL. Overridable via app config for tests.
  defp loops_api_url,
    do: Application.get_env(:dhc, :loops_api_url, "https://app.loops.so/api/v1/transactional")

  @impl Worker
  def perform(%Oban.Job{args: args}) do
    with :ok <- validate_args(args),
         :ok <- send_email(args) do
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[email-worker] Job failed: #{inspect(reason)}",
          email: args["email"],
          transactional_id: args["transactional_id"]
        )

        error
    end
  end

  defp validate_args(args) do
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
        Sentry.capture_message(message, level: :error, extra: %{args: args})
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

  defp send_email(%{"email" => email, "transactional_id" => transactional_id} = args) do
    if skip_send?() do
      Logger.info("[email-worker] Skipping email send in non-prod environment",
        email: email,
        transactional_id: transactional_id,
        data_variables: inspect(args["data_variables"])
      )

      :ok
    else
      post_to_loops(args)
    end
  end

  defp skip_send?, do: env() != :prod

  defp env do
    Application.get_env(:dhc, :environment, :development)
  end

  defp post_to_loops(%{"email" => email, "transactional_id" => transactional_id} = args) do
    api_key = loops_api_key()

    if is_nil(api_key) or api_key == "" do
      Logger.error("[email-worker] LOOPS_API_KEY not configured")
      {:error, :api_key_not_configured}
    else
      data_variables = Map.get(args, "data_variables", %{})

      payload = %{
        email: email,
        transactionalId: transactional_id,
        dataVariables: data_variables
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      case Req.post(loops_api_url(), json: payload, headers: headers) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          Logger.info("[email-worker] Email sent successfully",
            email: email,
            transactional_id: transactional_id
          )

          :ok

        {:ok, %Req.Response{status: status} = response} ->
          Logger.error("[email-worker] Loops API returned #{status}",
            email: email,
            transactional_id: transactional_id,
            status: status,
            body: inspect(response.body)
          )

          {:error, {:loops_api, status}}

        {:error, exception} ->
          Logger.error("[email-worker] HTTP request failed: #{inspect(exception)}")
          {:error, {:http_error, exception}}
      end
    end
  end

  defp loops_api_key do
    Application.get_env(:dhc, :loops_api_key)
  end
end
