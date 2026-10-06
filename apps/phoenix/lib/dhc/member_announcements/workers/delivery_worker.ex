defmodule Dhc.MemberAnnouncements.Workers.DeliveryWorker do
  @moduledoc """
  Delivers one Member Announcement (ADR 0028). Job args:
  `%{"announcement_id" => uuid}`; one job per announcement, inserted in the
  same transaction as the row.

  Outcomes:

    * a row that is already `sent` or `failed` is left alone (`:ok`);
    * success stamps `sent` and `sent_at`;
    * a provider rejection (4xx other than 429) cannot be fixed by retrying:
      the row is marked `failed`, Sentry is told, and the job is cancelled;
    * anything else (429, 5xx, network) is retried with Oban's backoff. The
      batch idempotency keys (see `Dhc.MemberAnnouncements.Delivery`) make a
      retry safe. The last attempt that still fails marks the row `failed`.
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:announcement_id], states: :all]

  require Logger

  alias Dhc.MemberAnnouncements.Announcement
  alias Dhc.MemberAnnouncements.Delivery
  alias Dhc.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"announcement_id" => id}} = job) do
    case Repo.get(Announcement, id) do
      nil ->
        {:cancel, :announcement_not_found}

      %Announcement{status: :queued} = announcement ->
        deliver(announcement, job)

      %Announcement{} ->
        :ok
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp deliver(announcement, job) do
    case Delivery.deliver(announcement) do
      :ok ->
        mark(announcement, status: :sent, sent_at: DateTime.utc_now(), failure_reason: nil)

        Logger.info("[member-announcements] Announcement sent",
          announcement_id: announcement.id,
          recipient_count: announcement.recipient_count
        )

        :ok

      {:error, {status, _body} = reason}
      when is_integer(status) and status in 400..499 and status != 429 ->
        fail(announcement, "Email provider rejected the announcement (HTTP #{status})", reason)
        {:cancel, {:provider_rejected, status}}

      {:error, reason} ->
        if job.attempt >= job.max_attempts do
          fail(announcement, "Email provider unavailable after #{job.attempt} attempts", reason)
        else
          Logger.warning("[member-announcements] Transient delivery failure; Oban will retry",
            announcement_id: announcement.id,
            reason: inspect(reason)
          )
        end

        {:error, reason}
    end
  end

  defp fail(announcement, message, reason) do
    mark(announcement, status: :failed, failure_reason: message)

    Logger.error("[member-announcements] #{message}",
      announcement_id: announcement.id,
      reason: inspect(reason)
    )

    Sentry.capture_message(message,
      level: :error,
      extra: %{announcement_id: announcement.id, reason: inspect(reason)}
    )
  end

  defp mark(announcement, changes) do
    announcement
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end
end
