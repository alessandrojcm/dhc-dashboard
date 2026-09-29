defmodule Dhc.TrainingAnnouncements.Workers.HolidayAnnouncementWorker do
  @moduledoc "Day-before driver and same-day frozen-evidence recovery, independent of roll-call lifecycle."
  use Oban.Worker, queue: :training_announcements

  alias Dhc.TrainingAnnouncements.HolidayAnnouncements

  @impl Oban.Worker
  def perform(job, opts \\ [])

  def perform(%Oban.Job{args: %{"holiday_date" => date, "phase" => "day_before"}} = job, opts) do
    case Date.from_iso8601(date) do
      {:ok, date} ->
        HolidayAnnouncements.perform(
          date,
          "day_before",
          job,
          Keyword.get(opts, :clock, &DateTime.utc_now/0)
        )

      _ ->
        {:discard, :invalid_args}
    end
  end

  def perform(%Oban.Job{args: %{"holiday_date" => date, "phase" => "same_day"}} = job, opts) do
    case Date.from_iso8601(date) do
      {:ok, date} ->
        HolidayAnnouncements.recover(date, job, Keyword.get(opts, :clock, &DateTime.utc_now/0))

      _ ->
        {:discard, :invalid_args}
    end
  end

  def perform(_job, _opts), do: {:discard, :invalid_args}
end
