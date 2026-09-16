defmodule Dhc.Notifications.Workers.WebPushWorker do
  @moduledoc """
  ALE-299: pushes one committed notification to every browser of its recipient.

  Enqueued by `Dhc.Notifications.WebPush.enqueue_delivery/1` *after* the
  notification row is durable, so the job can only ever find a real row (or
  none, if it was deleted meanwhile — then it cancels rather than retries).

  `max_attempts: 1` is deliberate. `WebPush.deliver/1` attempts every
  subscription once and reports per-browser outcomes; a job-level retry would
  re-push to the browsers that already succeeded, which is the duplicate the
  ticket forbids. A push service that is down loses one best-effort push; the
  notification centre still has the row. `unique` on the notification id keeps
  a double enqueue (a retried creator) from producing two pushes.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 1,
    unique: [period: :infinity, keys: [:notification_id], states: :incomplete]

  require Logger

  alias Dhc.Notifications.Notification
  alias Dhc.Notifications.WebPush
  alias Dhc.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    case Repo.get(Notification, notification_id) do
      nil ->
        {:cancel, :notification_missing}

      %Notification{} = notification ->
        report = WebPush.deliver(notification)

        if report.failed > 0 do
          Logger.warning(
            "[web-push] notification #{notification_id}: #{report.sent} sent, #{report.removed} removed, #{report.failed} failed"
          )
        end

        :ok
    end
  end
end
