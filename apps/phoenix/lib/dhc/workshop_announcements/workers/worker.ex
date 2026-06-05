defmodule Dhc.WorkshopAnnouncements.Worker do
  @moduledoc """
  Oban worker that processes workshop announcement requests and fans out
  to Discord and Email queues.

  Migrated from the `process-workshop-announcements` Deno edge function.
  Each job represents a single workshop announcement (replacing the pgmq
  batch-read pattern). The worker validates the announcement, looks up the
  workshop, formats messages, and enqueues downstream jobs.

  ## Job args

    * `workshop_id` — UUID of the workshop to announce
    * `announcement_type` — one of `created`, `status_changed`, `time_changed`,
      `location_changed`

  ## Fan-out pattern

    * One `Dhc.Discord.Worker` job per announcement type (batched message)
    * One `Dhc.Email.Worker` job per active member per announcement

  Oban handles retries with exponential backoff. If the workshop is not found
  or args are invalid, the job returns `{:error, reason}` and will be retried
  up to `max_attempts` times.
  """

  use Oban.Worker, queue: :announcements, max_attempts: 3

  require Logger

  alias Dhc.WorkshopAnnouncements
  alias Dhc.Discord.Worker, as: DiscordWorker
  alias Dhc.Email.Worker, as: EmailWorker

  @announcement_types ~w(created status_changed time_changed location_changed)

  @impl Worker
  def perform(%Oban.Job{args: args}) do
    with :ok <- validate_args(args),
         {:ok, workshop} <- WorkshopAnnouncements.fetch_workshop(args["workshop_id"]),
         :ok <- fan_out(workshop, args["announcement_type"]) do
      :ok
    else
      {:error, reason} = error ->
        Logger.error("[workshop-announcements-worker] Job failed: #{inspect(reason)}",
          workshop_id: args["workshop_id"],
          announcement_type: args["announcement_type"]
        )

        error
    end
  end

  defp validate_args(args) do
    errors =
      []
      |> validate_required(args, "workshop_id")
      |> validate_uuid(args)
      |> validate_required(args, "announcement_type")
      |> validate_announcement_type(args)

    case errors do
      [] ->
        :ok

      errors ->
        message = "Invalid workshop announcement job args: #{Enum.join(errors, ", ")}"
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

  defp validate_uuid(errors, %{"workshop_id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> errors
      :error -> ["invalid workshop_id format" | errors]
    end
  end

  defp validate_uuid(errors, _args), do: errors

  defp validate_announcement_type(errors, %{"announcement_type" => type})
       when type in @announcement_types,
       do: errors

  defp validate_announcement_type(errors, _args),
    do: ["invalid announcement_type" | errors]

  defp fan_out(workshop, announcement_type) do
    discord_jobs = build_discord_jobs(workshop, announcement_type)
    email_jobs = build_email_jobs(workshop, announcement_type)

    all_jobs = discord_jobs ++ email_jobs

    case Oban.insert_all(all_jobs) do
      [_ | _] = inserted ->
        Logger.info(
          "[workshop-announcements-worker] Enqueued #{length(inserted)} downstream jobs",
          workshop_id: workshop.id,
          announcement_type: announcement_type,
          discord_jobs: length(discord_jobs),
          email_jobs: length(email_jobs)
        )

        :ok

      [] ->
        Logger.info("[workshop-announcements-worker] No downstream jobs to enqueue",
          workshop_id: workshop.id,
          announcement_type: announcement_type
        )

        :ok
    end
  end

  defp build_discord_jobs(workshop, announcement_type) do
    if workshop.announce_discord do
      message = WorkshopAnnouncements.format_discord_message(workshop, announcement_type)

      [
        DiscordWorker.new(%{
          "message" => message,
          "workshop_id" => workshop.id,
          "announcement_type" => announcement_type
        })
      ]
    else
      []
    end
  end

  defp build_email_jobs(workshop, announcement_type) do
    if workshop.announce_email do
      message = WorkshopAnnouncements.format_email_message(workshop, announcement_type)
      users = WorkshopAnnouncements.list_active_users()

      Logger.info(
        "[workshop-announcements-worker] Preparing email jobs for #{length(users)} active users",
        workshop_id: workshop.id,
        announcement_type: announcement_type
      )

      Enum.map(users, fn user ->
        EmailWorker.new(%{
          "email" => user.email,
          "transactional_id" => "workshopAnnouncement",
          "data_variables" => %{
            "first_name" => user.first_name,
            "last_name" => user.last_name,
            "message" => message,
            "workshop_count" => 1
          }
        })
      end)
    else
      []
    end
  end
end
