defmodule Dhc.TrainingAnnouncements.Workers.AnnouncementWorker do
  @moduledoc "Disposable driver of one Announcement Occurrence; delivery rows are the evidence."
  use Oban.Worker, queue: :training_announcements

  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Channels
  alias Dhc.TrainingAnnouncements.Copy
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery
  alias Dhc.TrainingAnnouncements.Occurrences
  alias Dhc.TrainingAnnouncements.Scheduling
  alias Dhc.TrainingAnnouncements.Store

  @impl Oban.Worker
  def perform(job, opts \\ [])

  def perform(%Oban.Job{args: %{"announcement_id" => id, "occurrence_date" => date}}, opts) do
    with {:ok, id} <- Ecto.UUID.cast(id), {:ok, date} <- Date.from_iso8601(date) do
      # Fetch-on-miss can use HTTP. Obtain holiday facts before claiming a row,
      # then read the clock and authoritative inputs inside the transaction.
      clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
      holidays = holidays_on(id, date)
      finish(Store.with_current(id, &run(&1, date, clock.(), holidays)))
    else
      _ -> {:discard, :invalid_args}
    end
  end

  def perform(_job, _opts), do: {:discard, :invalid_args}

  defp finish({:ok, delivery}) do
    report_blocked(delivery)
    :ok
  end

  defp finish({:error, :not_found}), do: :ok
  defp finish({:error, reason}), do: {:error, reason}

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
        advance(announcement, date, now, outcome(occurrence, now))
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
    with {:ok, _channel} <- Channels.for_kind(occurrence.kind),
         {:ok, _copy} <- Copy.render(occurrence, occurrence.date) do
      # ALE-325 attaches freeze-and-post here. Until then a deliverable slot
      # must not manufacture delivery evidence or call Discord.
      nil
    else
      {:error, :unconfigured_channel} -> {"blocked", "unconfigured_channel"}
      {:error, _errors} -> {"blocked", "invalid_copy"}
    end
  end

  defp advance(announcement, date, now, outcome) do
    delivery = record(announcement.id, date, now, outcome)
    enqueue_next!(announcement, now, date)
    delivery
  end

  defp enqueue_next!(announcement, now, date) do
    case Scheduling.enqueue_next(announcement, now, date) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp report_blocked(%{state: "blocked"} = delivery) do
    Sentry.capture_message("Training Announcement delivery blocked",
      level: :error,
      extra: %{
        delivery_id: delivery.id,
        announcement_id: delivery.announcement_id,
        occurrence_date: Date.to_iso8601(delivery.occurrence_date),
        reason: delivery.reason
      }
    )
  end

  defp report_blocked(_delivery), do: :ok

  defp record(_id, _date, _now, nil), do: nil

  defp record(id, date, now, {state, reason}) do
    attrs = %{
      id: Ecto.UUID.generate(),
      announcement_id: id,
      subject: "occurrence",
      occurrence_date: date,
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
