defmodule Dhc.WorkshopCalendar.Workers.RepairWorker do
  @moduledoc "Current-state repair also discovers obligations whose source has been deleted."
  use Oban.Worker, queue: :workshop_calendar, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: Dhc.WorkshopCalendar.repair()
end
