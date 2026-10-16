defmodule Dhc.Notifications.Workers.RetentionWorker do
  @moduledoc """
  Nightly cron driver for `Dhc.Notifications.Retention.prune/1`: deletes
  Notifications older than three months.

  A missed or failed pass is harmless; the next one deletes everything that
  has aged out since. `unique` over incomplete states keeps overlapping ticks
  from piling up.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  require Logger

  alias Dhc.Notifications.Retention

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted = Retention.prune()
    Logger.info("Notification retention pass deleted #{deleted} notifications")
    :ok
  end
end
