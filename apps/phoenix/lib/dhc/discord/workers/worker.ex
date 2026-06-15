defmodule Dhc.Discord.Worker do
  @moduledoc """
  Oban worker that sends messages to a Discord channel via webhook.

  Migrated from the `process-discord` Deno edge function. Each job represents
  a single Discord notification (one Oban job per message, replacing the
  pgmq batch-read pattern).

  ## Job args

    * `message` — the text body to post (prepended with `@everyone`)
    * `workshop_id` — UUID of the related workshop
    * `announcement_type` — one of `created`, `status_changed`, `time_changed`, `location_changed`

  ## Environment behaviour

    * **dev/test** — skips the HTTP call and logs the message instead
    * **prod** — POSTs to the `DISCORD_WEBHOOK_URL` environment variable

  Oban handles retries with exponential backoff. If the Discord API returns
  a non-2xx response, the job returns `{:error, reason}` and will be retried
  up to `max_attempts` times.
  """

  use Oban.Worker, queue: :discord, max_attempts: 3

  require Logger

  @announcement_types ~w(created status_changed time_changed location_changed)

  @impl Worker
  def perform(%Oban.Job{args: args}) do
    with :ok <- validate_args(args),
         :ok <- send_message(args) do
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[discord-worker] Job failed: #{inspect(reason)}",
          workshop_id: args["workshop_id"],
          announcement_type: args["announcement_type"]
        )

        error
    end
  end

  defp validate_args(args) do
    errors =
      []
      |> validate_required(args, "message")
      |> validate_required(args, "workshop_id")
      |> validate_required(args, "announcement_type")
      |> validate_announcement_type(args)

    case errors do
      [] ->
        :ok

      errors ->
        message = "Invalid Discord job args: #{Enum.join(errors, ", ")}"
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

  defp validate_announcement_type(errors, %{"announcement_type" => type})
       when type in @announcement_types,
       do: errors

  defp validate_announcement_type(errors, _args),
    do: ["invalid announcement_type" | errors]

  defp send_message(%{"message" => message} = args) do
    if skip_send?() do
      Logger.info("[discord-worker] Skipping Discord send in non-prod environment",
        workshop_id: args["workshop_id"],
        announcement_type: args["announcement_type"]
      )

      :ok
    else
      post_to_discord(message)
    end
  end

  defp skip_send?, do: env() != :prod

  defp env do
    Application.get_env(:dhc, :environment, :development)
  end

  defp post_to_discord(message) do
    webhook_url = webhook_url()

    if is_nil(webhook_url) or webhook_url == "" do
      Logger.error("[discord-worker] DISCORD_WEBHOOK_URL not configured")
      {:error, :webhook_url_not_configured}
    else
      payload = %{
        content: "Hey @everyone!\n#{message}",
        allowed_mentions: %{parse: ["everyone"]}
      }

      case Req.post(webhook_url, json: payload) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          Logger.info("[discord-worker] Message sent successfully")
          :ok

        {:ok, %Req.Response{status: status} = response} ->
          Logger.error("[discord-worker] Discord API returned #{status}",
            status: status,
            body: inspect(response.body)
          )

          {:error, {:discord_api, status}}

        {:error, exception} ->
          Logger.error("[discord-worker] HTTP request failed: #{inspect(exception)}")
          {:error, {:http_error, exception}}
      end
    end
  end

  defp webhook_url do
    Application.get_env(:dhc, :discord_webhook_url)
  end
end
