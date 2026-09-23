defmodule Dhc.ClubCalendar do
  @moduledoc """
  The club's shared calendar: "today in Europe/Dublin", civil-time ↔ UTC
  conversion, and the durable Irish bank-holiday cache (ALE-318, ALE-319).

  Inventory loan dates and Training Announcement occurrences both ask here
  which day it is and whether a date is a bank holiday; no other context
  keeps its own copy of either fact.

  Civil-time work is pure Elixir on the `tz` time-zone database
  (compile-time IANA data, no updater process): `today/0`, `on_date/1`, and
  `to_utc/2` never round-trip through Postgres, so DST-edge behaviour is
  unit-testable without a database.

  Bank holidays come from the OpenHolidays API (`IE`, per calendar year) and
  are cached in `club_calendar_holidays`, keyed by date. `holiday_on/1`
  fetches a year it has never seen and answers from the cache; the daily
  `Dhc.ClubCalendar.Workers.HolidayRefreshWorker` re-fetches the current and
  next year, upserting by date and deleting dates the source no longer
  returns. A source failure fails open (no holiday), leaves cached rows
  untouched, logs, and reports to Sentry — a normal training night is never
  silently skipped, and there is no staleness UI.
  """

  import Ecto.Query

  require Logger

  alias Dhc.ClubCalendar.Holiday
  alias Dhc.ClubCalendar.OpenHolidays
  alias Dhc.Repo

  @zone "Europe/Dublin"

  @doc "The club's time-zone name, for documentation and error messages."
  @spec zone() :: String.t()
  def zone, do: @zone

  @doc """
  Today's date in the club's time zone.
  """
  @spec today() :: Date.t()
  def today do
    @zone
    |> DateTime.now!(Tz.TimeZoneDatabase)
    |> DateTime.to_date()
  end

  @doc """
  The club's calendar day containing `at`.

  Needed wherever a stored UTC timestamp has to be compared with a loan
  date: a handover at 23:30 UTC on the 1st is already the 2nd in Dublin
  summer time, so converting with `DateTime.to_date/1` would compare the
  wrong day.
  """
  @spec on_date(DateTime.t()) :: Date.t()
  def on_date(%DateTime{} = at) do
    at
    |> DateTime.shift_zone!(@zone, Tz.TimeZoneDatabase)
    |> DateTime.to_date()
  end

  @doc """
  Turns a Dublin civil date + wall-clock time into the UTC instant a
  scheduled post fires at.

  Wall times in the spring-forward gap resolve to the post-gap instant;
  ambiguous autumn times resolve to their first occurrence. Evening post
  times never hit either case; the policy exists so the function is total.
  """
  @spec to_utc(Date.t(), Time.t()) :: DateTime.t()
  def to_utc(%Date{} = date, %Time{} = time) do
    resolved =
      case DateTime.new(date, time, @zone, Tz.TimeZoneDatabase) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, _before, after_gap} -> after_gap
      end

    DateTime.shift_zone!(resolved, "Etc/UTC", Tz.TimeZoneDatabase)
  end

  @doc """
  Answers whether `date` is an Irish bank holiday from the durable cache.

  A year never fetched is fetched from OpenHolidays, stored, and answered.
  A source failure fails open as `{:ok, nil}`: cached rows are untouched,
  the failure is logged, and a Sentry event is emitted.
  """
  @spec holiday_on(Date.t()) :: {:ok, Holiday.t() | nil}
  def holiday_on(%Date{} = date) do
    case Repo.get(Holiday, date) do
      %Holiday{} = holiday ->
        {:ok, holiday}

      nil ->
        if year_fetched?(date.year) do
          {:ok, nil}
        else
          fetch_year_on_miss(date.year)
          {:ok, Repo.get(Holiday, date)}
        end
    end
  end

  @doc """
  Returns every cached holiday in the inclusive Dublin date range, ordered
  by date — the holiday set the pure occurrence projection receives.

  Years in the range never fetched are fetched first (fail-open per year),
  so a scheduled window over a fresh year still answers from the source.
  """
  @spec holidays_between(Date.t(), Date.t()) :: {:ok, [Holiday.t()]}
  def holidays_between(%Date{} = from, %Date{} = to) do
    {from, to} =
      if Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}

    Enum.each(from.year..to.year, fn year ->
      unless year_fetched?(year), do: fetch_year_on_miss(year)
    end)

    holidays =
      Repo.all(
        from h in Holiday,
          where: h.date >= ^from and h.date <= ^to,
          order_by: h.date
      )

    {:ok, holidays}
  end

  @doc """
  Re-fetches `year` from OpenHolidays, upserts every returned date, and
  deletes cached dates of that year the source no longer returns — the
  daily refresh pass and the late-correction path in one function.

  An empty source response is treated as a source error (a year with no
  Irish bank holidays is almost certainly a broken response): cached rows
  stay untouched. Every source failure is logged, reported to Sentry, and
  returned; callers that run on a schedule (the refresh worker) succeed
  anyway so the next daily pass repairs the miss.
  """
  @spec refresh_year(integer()) :: :ok | {:error, term()}
  def refresh_year(year) when is_integer(year) and year > 0 do
    case ingest_year(year, :refresh) do
      {:ok, dates} ->
        prune_stale(year, dates)
        :ok

      {:error, _} = error ->
        error
    end
  end

  # Fetch-on-miss shares the refresh ingest (strict shape, empty response
  # reported, failures logged) but never prunes and never fails: the caller
  # answers from whatever the cache holds.
  defp fetch_year_on_miss(year) do
    ingest_year(year, :fetch_on_miss)
    :ok
  end

  defp ingest_year(year, op) do
    case OpenHolidays.fetch_year(year) do
      {:ok, []} ->
        report_source_error(op, year, :empty_response)
        {:error, :empty_response}

      {:ok, rows} ->
        store_rows(rows)
        {:ok, Enum.map(rows, & &1.date)}

      {:error, reason} ->
        report_source_error(op, year, reason)
        {:error, reason}
    end
  end

  defp year_range(year) do
    {Date.new!(year, 1, 1), Date.new!(year, 12, 31)}
  end

  defp year_fetched?(year) do
    {first, last} = year_range(year)
    Repo.exists?(from h in Holiday, where: h.date >= ^first and h.date <= ^last)
  end

  defp store_rows(rows) do
    fetched_at = DateTime.utc_now()
    entries = Enum.map(rows, &Map.put(&1, :fetched_at, fetched_at))

    Repo.insert_all(Holiday, entries,
      on_conflict: {:replace_all_except, [:date]},
      conflict_target: :date
    )
  end

  defp prune_stale(year, dates) do
    {first, last} = year_range(year)

    Repo.delete_all(
      from h in Holiday,
        where: h.date >= ^first and h.date <= ^last and h.date not in ^dates
    )
  end

  defp report_source_error(op, year, reason) do
    Logger.warning("[club-calendar] OpenHolidays fetch failed",
      year: year,
      reason: "#{inspect(op)}: #{inspect(reason)}"
    )

    Sentry.capture_message("OpenHolidays holiday fetch failed",
      level: :error,
      extra: %{op: op, year: year, reason: inspect(reason)}
    )
  end
end
