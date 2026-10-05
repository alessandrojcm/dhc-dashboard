defmodule Dhc.TrainingAnnouncements.Scheduling do
  @moduledoc """
  The only writer of Training Announcement jobs. Creation, schedule edits,
  retirement and deletion use this boundary inside their own transaction;
  workers advance the same schedule after processing an occurrence.
  Disablement and copy changes never rewrite a job.
  """
  import Ecto.Query

  alias Dhc.ClubCalendar
  alias Dhc.TrainingAnnouncements.HolidayAnnouncements
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker
  alias Dhc.TrainingAnnouncements.Workers.HolidayAnnouncementWorker

  # Scheduling owns driver identity. Executing/retryable jobs intentionally
  # do not block the next driver; delivery-row uniqueness is the duplicate fence.
  @driver_unique [
    period: :infinity,
    fields: [:worker, :args],
    keys: [:announcement_id],
    states: [:available, :scheduled]
  ]

  # Call before the write seam. The authoritative enqueue below only reads the
  # cache; a concurrently changed schedule may fail open until its next run.
  def prefetch_next(announcement, now, after_date \\ nil) do
    if announcement.kind == "roll_call" do
      case next_date(announcement, now, after_date) do
        nil -> :ok
        date -> ClubCalendar.holiday_on(date)
      end
    end

    :ok
  end

  def cancel(announcement_id) do
    Oban.cancel_all_jobs(
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(AnnouncementWorker),
        where: fragment("?->>'announcement_id' = ?", j.args, ^announcement_id)
      )
    )
  end

  def enqueue_next(announcement, now, after_date \\ nil) do
    case next_date(announcement, now, after_date) do
      nil ->
        {:ok, nil}

      date ->
        result =
          %{announcement_id: announcement.id, occurrence_date: Date.to_iso8601(date)}
          |> AnnouncementWorker.new(
            scheduled_at: ClubCalendar.to_utc(date, announcement.post_time),
            unique: @driver_unique,
            replace: [scheduled: [:scheduled_at, :args]]
          )
          |> Oban.insert()

        with {:ok, _} <- result,
             {:ok, _} <- enqueue_holiday(announcement, date, now) do
          result
        end
    end
  end

  defp enqueue_holiday(%{kind: "roll_call"} = announcement, date, now) do
    post_time = HolidayAnnouncements.driver_post_time(date, now) || announcement.post_time
    at = ClubCalendar.to_utc(Date.add(date, -1), post_time)

    if DateTime.compare(at, now) == :gt do
      case ClubCalendar.cached_holiday_on(date) do
        nil ->
          {:ok, nil}

        _holiday ->
          %{holiday_date: Date.to_iso8601(date), phase: "day_before"}
          |> HolidayAnnouncementWorker.new(
            scheduled_at: at,
            unique: [
              period: :infinity,
              fields: [:worker, :args],
              keys: [:holiday_date, :phase],
              states: [:available, :scheduled]
            ],
            replace: [scheduled: [:scheduled_at]]
          )
          |> Oban.insert()
      end
    else
      {:ok, nil}
    end
  end

  defp enqueue_holiday(_announcement, _date, _now), do: {:ok, nil}

  # Commit this independent recovery driver with a same-day holiday freeze.
  # Deleting/retiring its triggering roll call must not abandon frozen evidence.
  def enqueue_holiday_recovery(date, now) do
    %{holiday_date: Date.to_iso8601(date), phase: "same_day"}
    |> HolidayAnnouncementWorker.new(
      scheduled_at: DateTime.add(now, 60, :second),
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        keys: [:holiday_date, :phase],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Oban.insert()
  end

  def reschedule(announcement, now) do
    # A scheduled conflict is replaced by Oban. An available conflict isn't:
    # cancel that obsolete driver in the same transaction before inserting.
    Oban.cancel_all_jobs(
      from(j in Oban.Job,
        where: j.worker == ^Oban.Worker.to_string(AnnouncementWorker),
        where: j.state == "available",
        where: fragment("?->>'announcement_id' = ?", j.args, ^announcement.id)
      )
    )

    enqueue_next(announcement, now)
  end

  def next_date(%{retired: true}, _now, _after_date), do: nil

  def next_date(announcement, now, after_date) do
    today = ClubCalendar.on_date(now)

    from =
      if after_date && Date.compare(after_date, today) != :lt,
        do: Date.add(after_date, 1),
        else: today

    dates =
      if announcement.weekday,
        do: Date.range(from, Date.add(from, 7)),
        else: [announcement.one_off_date]

    Enum.find(dates, fn date ->
      Date.compare(date, from) != :lt and
        (is_nil(announcement.weekday) or Date.day_of_week(date) == announcement.weekday) and
        DateTime.compare(ClubCalendar.to_utc(date, announcement.post_time), now) == :gt
    end)
  end
end
