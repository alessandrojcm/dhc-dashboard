defmodule Dhc.TrainingAnnouncements.HolidayAnnouncements do
  @moduledoc "Fixed holiday heads-ups, identified by holiday date and phase rather than a roll call."
  import Ecto.Query

  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.Channels
  alias Dhc.TrainingAnnouncements.Copy
  alias Dhc.TrainingAnnouncements.Delivery
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence
  alias Dhc.TrainingAnnouncements.Occurrences
  alias Dhc.TrainingAnnouncements.Scheduling
  alias Dhc.TrainingAnnouncements.Store

  @copy %{
    "day_before" =>
      "⚠️ Heads up @everyone! Tomorrow is {{holidayName}} (a bank holiday), so there will be no training. Enjoy your day off! 🎉",
    "same_day" =>
      "⚠️ Reminder @everyone: Today is {{holidayName}} (a bank holiday), so there will be no training. See you next time! 🎉"
  }

  def perform(date, phase, job, clock) do
    existing = Repo.one(from(d in Evidence, where: d.holiday_date == ^date and d.phase == ^phase))

    if existing do
      Delivery.progress(existing, job, clock)
    else
      resolve_and_progress(date, phase, job, clock)
    end
  end

  def recover(date, job, clock) do
    Repo.one(from(d in Evidence, where: d.holiday_date == ^date and d.phase == "same_day"))
    |> Delivery.progress(job, clock)
  end

  defp resolve_and_progress(date, phase, job, clock, retries \\ 3) do
    with {:ok, holiday} when not is_nil(holiday) <- ClubCalendar.holiday_on(date),
         announcement when not is_nil(announcement) <- eligible(date) do
      result = Store.with_current(announcement.id, &claim(&1, date, phase, clock))

      case result do
        {:ok, :reselect} when retries > 0 ->
          resolve_and_progress(date, phase, job, clock, retries - 1)

        {:ok, :reselect} ->
          {:error, :concurrent_change}

        {:ok, {:delivery, delivery}} ->
          Delivery.report_failure(delivery)
          Delivery.progress(delivery, job, clock)

        {:ok, outcome} ->
          outcome

        {:error, :not_found} when retries > 0 ->
          resolve_and_progress(date, phase, job, clock, retries - 1)

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> :ok
    end
  end

  defp claim(announcement, date, phase, clock) do
    with true <-
           announcement.enabled and not announcement.retired and announcement.kind == "roll_call",
         occurrence when not is_nil(occurrence) <- Occurrences.resolve_due(announcement, date, []),
         holiday when not is_nil(holiday) <- ClubCalendar.cached_holiday_on(date) do
      now = clock.()
      at = ClubCalendar.to_utc(send_date(date, phase), announcement.post_time)

      if DateTime.compare(at, now) == :gt do
        {:snooze, max(1, DateTime.diff(at, now, :second))}
      else
        {:delivery, record(holiday, phase, announcement.post_time, now)}
      end
    else
      false -> :reselect
      nil -> :reselect
    end
  end

  defp eligible(date) do
    Enum.find(candidates(date), & &1.enabled)
  end

  # A date-wide driver uses the earliest live roll-call slot. Disablement must
  # not rewrite jobs: enabled candidates are selected again at run time.
  def driver_post_time(date, now) do
    # An elapsed disabled slot must not hide a still-future enabled slot.
    case Enum.filter(candidates(date), fn announcement ->
           DateTime.compare(
             ClubCalendar.to_utc(send_date(date, "day_before"), announcement.post_time),
             now
           ) == :gt
         end) do
      [announcement | _] -> announcement.post_time
      [] -> nil
    end
  end

  defp candidates(date) do
    weekday = Date.day_of_week(date)

    Repo.all(
      from(a in Announcement,
        where: a.kind == "roll_call" and not a.retired,
        where: a.weekday == ^weekday or a.one_off_date == ^date,
        order_by: [asc: a.post_time, asc: a.id]
      )
    )
  end

  defp record(holiday, phase, post_time, now) do
    snapshot =
      if Date.compare(send_date(holiday.date, phase), ClubCalendar.on_date(now)) == :lt,
        do: %{state: "missed", reason: "late", concluded_at: now},
        else: freeze_snapshot(holiday, phase, post_time, now)

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          subject: "holiday",
          holiday_date: holiday.date,
          phase: phase,
          created_at: now,
          updated_at: now
        },
        snapshot
      )

    case Repo.insert_all(Evidence, [attrs], on_conflict: :nothing, returning: true) do
      {1, [%{state: "frozen", phase: "same_day"} = delivery]} ->
        Store.persist!(Scheduling.enqueue_holiday_recovery(holiday.date, now))
        delivery

      {1, [delivery]} ->
        delivery

      {0, []} ->
        nil
    end
  end

  defp freeze_snapshot(holiday, phase, post_time, now) do
    source = Map.fetch!(@copy, phase)

    with {:ok, channel} <- Channels.for_kind("holiday"),
         {:ok, message} <-
           Copy.render_holiday_message(source, %{date: holiday.date, holiday_name: holiday.name}) do
      %{
        state: "frozen",
        frozen_at: now,
        post_time: post_time,
        mention_everyone: true,
        message_source: source,
        rendered_message: message,
        channel_id: channel
      }
    else
      {:error, :unconfigured_channel} ->
        %{state: "blocked", reason: "unconfigured_channel", concluded_at: now}

      {:error, _} ->
        %{state: "blocked", reason: "invalid_copy", concluded_at: now}
    end
  end

  defp send_date(date, "day_before"), do: Date.add(date, -1)
  defp send_date(date, "same_day"), do: date
end
