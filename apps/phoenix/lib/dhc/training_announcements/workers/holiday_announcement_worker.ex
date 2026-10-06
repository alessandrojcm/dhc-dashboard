defmodule Dhc.TrainingAnnouncements.Workers.HolidayAnnouncementWorker do
  @moduledoc """
  Day-before driver and same-day frozen-evidence recovery, independent of
  roll-call lifecycle. It only turns job arguments into an
  `Execution.evaluate/3` call.
  """
  use Oban.Worker, queue: :training_announcements

  alias Dhc.TrainingAnnouncements.Execution

  @impl Oban.Worker
  def perform(job, opts \\ [])

  def perform(%Oban.Job{args: %{"holiday_date" => date, "phase" => phase}} = job, opts)
      when phase in ["day_before", "same_day"] do
    case Date.from_iso8601(date) do
      {:ok, date} ->
        clock = Keyword.get_lazy(opts, :clock, &Execution.clock/0)
        Execution.evaluate({:holiday, phase, date}, clock, job)

      _ ->
        {:discard, :invalid_args}
    end
  end

  def perform(_job, _opts), do: {:discard, :invalid_args}
end
