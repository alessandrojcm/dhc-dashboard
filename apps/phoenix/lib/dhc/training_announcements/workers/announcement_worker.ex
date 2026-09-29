defmodule Dhc.TrainingAnnouncements.Workers.AnnouncementWorker do
  @moduledoc "Disposable driver of one Announcement Occurrence; delivery rows are the evidence."
  use Oban.Worker, queue: :training_announcements

  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Channels
  alias Dhc.TrainingAnnouncements.Copy
  alias Dhc.TrainingAnnouncements.Delivery
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery
  alias Dhc.TrainingAnnouncements.Occurrences
  alias Dhc.TrainingAnnouncements.Scheduling
  alias Dhc.TrainingAnnouncements.Store

  @impl Oban.Worker
  def perform(job, opts \\ [])

  def perform(%Oban.Job{args: %{"announcement_id" => id, "occurrence_date" => date}} = job, opts) do
    with {:ok, id} <- Ecto.UUID.cast(id), {:ok, date} <- Date.from_iso8601(date) do
      # Fetch-on-miss can use HTTP. Obtain holiday facts before claiming a row,
      # then read the clock and authoritative inputs inside the transaction.
      clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
      holidays = holidays_on(id, date)

      finish(
        Store.with_current(id, &load_or_run(&1, date, clock, holidays)),
        job,
        clock
      )
    else
      _ -> {:discard, :invalid_args}
    end
  end

  def perform(_job, _opts), do: {:discard, :invalid_args}

  defp load_or_run(announcement, date, clock, holidays) do
    case Delivery.for_occurrence(announcement.id, date) do
      nil -> run(announcement, date, clock.(), holidays)
      delivery -> {:existing, delivery}
    end
  end

  defp finish({:ok, {:existing, delivery}}, job, clock),
    do: Delivery.progress(delivery, job, clock)

  defp finish({:ok, delivery}, job, clock) do
    Delivery.report_failure(delivery)
    Delivery.progress(delivery, job, clock)
  end

  defp finish({:error, :not_found}, _job, _clock), do: :ok
  defp finish({:error, reason}, _job, _clock), do: {:error, reason}

  defp run(%{retired: true}, _date, _now, _holidays), do: nil

  defp run(announcement, date, now, holidays) do
    entry = Store.entry(announcement)

    occurrence =
      Occurrences.resolve_due(announcement, date,
        suppressions: entry.suppressions,
        overrides: entry.overrides,
        holidays: holidays
      )

    due_at = ClubCalendar.to_utc(date, announcement.post_time)

    cond do
      is_nil(occurrence) ->
        # An edited schedule already owns a replacement driver. A stale job
        # must not move that new pending occurrence past its own obsolete date.
        nil

      DateTime.compare(due_at, now) == :gt ->
        # Complete this driver rather than snoozing into a second pending job
        # after a same-date time edit. Ensure the one future driver.
        enqueue_next!(announcement, now, nil)
        nil

      true ->
        advance(announcement, occurrence, now, outcome(occurrence, now))
    end
  end

  defp holidays_on(id, date) do
    case Store.fetch(id) do
      {:ok, %{kind: "roll_call", retired: false}} -> holiday_dates(date)
      _ -> MapSet.new()
    end
  end

  defp holiday_dates(date) do
    case ClubCalendar.holiday_on(date) do
      {:ok, nil} -> MapSet.new()
      {:ok, _holiday} -> MapSet.new([date])
    end
  end

  defp outcome(occurrence, now) do
    if Date.compare(occurrence.date, ClubCalendar.on_date(now)) == :lt do
      {"missed", "late"}
    else
      case occurrence.outcome do
        :skipped_holiday -> {"skipped", "holiday"}
        :skipped_disabled -> {"skipped", "disabled"}
        :skipped_suppressed -> {"skipped", "suppressed"}
        _ -> validate(occurrence)
      end
    end
  end

  defp validate(occurrence) do
    with {:ok, channel} <- Channels.for_kind(occurrence.kind),
         {:ok, copy} <- Copy.render(occurrence, occurrence.date) do
      {:freeze, channel, copy}
    else
      {:error, :unconfigured_channel} -> {"blocked", "unconfigured_channel"}
      {:error, _errors} -> {"blocked", "invalid_copy"}
    end
  end

  defp advance(announcement, occurrence, now, outcome) do
    delivery =
      case outcome do
        {:freeze, channel, copy} -> Delivery.freeze(announcement, occurrence, channel, copy, now)
        outcome -> record(announcement.id, occurrence, now, outcome)
      end

    enqueue_next!(announcement, now, occurrence.date)
    delivery
  end

  defp enqueue_next!(announcement, now, date) do
    case Scheduling.enqueue_next(announcement, now, date) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record(_id, _date, _now, nil), do: nil

  defp record(id, occurrence, now, {state, reason}) do
    attrs = %{
      id: Ecto.UUID.generate(),
      announcement_id: id,
      subject: "occurrence",
      occurrence_date: occurrence.date,
      applied_suppression_id: occurrence.applied_suppression_id,
      applied_override_id: occurrence.applied_override_id,
      state: state,
      reason: reason,
      concluded_at: now,
      created_at: now,
      updated_at: now
    }

    case Repo.insert_all(DiscordAnnouncementDelivery, [attrs],
           on_conflict: :nothing,
           returning: true
         ) do
      {1, [delivery]} -> delivery
      {0, []} -> nil
    end
  end
end
