defmodule Dhc.WorkshopCalendar.Workers.SyncWorker do
  @moduledoc "Identifier-only driver; durable retry and ownership live in the boundary."
  use Oban.Worker,
    queue: :workshop_calendar,
    max_attempts: 20,
    unique: [period: 60, fields: [:worker, :args], states: :incomplete]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_kind" => "workshop", "source_id" => id}}) do
    Dhc.WorkshopCalendar.sync(:workshop, id)
  end
end
