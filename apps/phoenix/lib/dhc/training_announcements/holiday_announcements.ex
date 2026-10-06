defmodule Dhc.TrainingAnnouncements.HolidayAnnouncements do
  @moduledoc """
  Fixed holiday heads-ups, identified by holiday date and phase rather than
  a roll call: their copy, their driving roll call and send dates.
  `Execution` writes and progresses their Evidence.
  """
  import Ecto.Query

  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.Copy

  @copy %{
    "day_before" =>
      "⚠️ Heads up @everyone! Tomorrow is {{holidayName}} (a bank holiday), so there will be no training. Enjoy your day off! 🎉",
    "same_day" =>
      "⚠️ Reminder @everyone: Today is {{holidayName}} (a bank holiday), so there will be no training. See you next time! 🎉"
  }

  @doc """
  The roll call that drives `date`'s Holiday Announcements: the earliest
  enabled, live roll-call slot scheduled that date. Shared by `Execution`
  and the read model.
  """
  def eligible(date), do: eligible_among(roll_calls(), date)

  @doc """
  `eligible/1` over already-loaded announcements, so a read model can pick
  every holiday's driver from one `roll_calls/0` load.
  """
  def eligible_among(announcements, date),
    do: announcements |> candidates(date) |> Enum.find(& &1.enabled)

  @doc "Every live roll call: the superset `candidates/2` selects drivers from."
  def roll_calls do
    Repo.all(from(a in Announcement, where: a.kind == "roll_call" and not a.retired))
  end

  # The one definition of which slots can drive `date`, earliest first.
  defp candidates(announcements, date) do
    weekday = Date.day_of_week(date)

    announcements
    |> Enum.filter(fn announcement ->
      announcement.kind == "roll_call" and not announcement.retired and
        (announcement.weekday == weekday or announcement.one_off_date == date)
    end)
    |> Enum.sort_by(&{Time.diff(&1.post_time, ~T[00:00:00], :microsecond), &1.id})
  end

  def preview(holiday, phase) do
    render_copy(holiday, phase)
  end

  defp render_copy(holiday, phase) do
    source = Map.fetch!(@copy, phase)

    with {:ok, message} <-
           Copy.render_holiday_message(source, %{date: holiday.date, holiday_name: holiday.name}) do
      {:ok, %{message_source: source, rendered_message: message}}
    end
  end

  # A date-wide driver uses the earliest live roll-call slot. Disablement must
  # not rewrite jobs: enabled candidates are selected again at run time.
  def driver_post_time(date, now) do
    # An elapsed disabled slot must not hide a still-future enabled slot.
    case Enum.filter(candidates(roll_calls(), date), fn announcement ->
           DateTime.compare(
             ClubCalendar.to_utc(send_date(date, "day_before"), announcement.post_time),
             now
           ) == :gt
         end) do
      [announcement | _] -> announcement.post_time
      [] -> nil
    end
  end

  def send_date(date, "day_before"), do: Date.add(date, -1)
  def send_date(date, "same_day"), do: date
end
