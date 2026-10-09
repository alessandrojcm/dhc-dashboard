defmodule Dhc.BeginnersWorkshops.IntakeEmails.Values do
  @moduledoc """
  Formats Beginners' Workshop facts into Intake Email placeholder values
  (ALE-377). Each format stays within its placeholder's maximum in
  `EmailType.maxima/0`: the longest date is `Wednesday 30 September 2026`
  (27), the longest deadline `Wednesday 30 September 2026, 23:59` (34), and a
  fee up to `€999.99` (7).

  Deadlines are instants and are shown on the Europe/Dublin wall clock.
  """

  alias Dhc.ClubCalendar

  @months ~w(January February March April May June July August September October November December)
  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  @doc "`Saturday 14 November 2026`"
  @spec date(Date.t()) :: String.t()
  def date(%Date{} = date) do
    weekday = Enum.at(@weekdays, Date.day_of_week(date) - 1)
    "#{weekday} #{date.day} #{Enum.at(@months, date.month - 1)} #{date.year}"
  end

  @doc "`10:00`"
  @spec start_time(Time.t()) :: String.t()
  def start_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")

  @doc "`Sunday 8 November 2026, 23:59`, on the Dublin wall clock."
  @spec deadline(DateTime.t()) :: String.t()
  def deadline(%DateTime{} = at) do
    "#{date(ClubCalendar.on_date(at))}, #{start_time(ClubCalendar.time_on(at))}"
  end

  @doc "`€50.00` from integer cents (the club prices everything in euro)."
  @spec money(non_neg_integer()) :: String.t()
  def money(cents) when is_integer(cents) and cents >= 0 do
    "€#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
