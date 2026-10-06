defmodule Dhc.TrainingAnnouncements.OccurrenceReads do
  @moduledoc "Calendar and rail read model. Durable rows win; history is never re-projected."
  import Ecto.Query
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.Copy
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence
  alias Dhc.TrainingAnnouncements.HolidayAnnouncements
  alias Dhc.TrainingAnnouncements.Occurrences
  alias Dhc.TrainingAnnouncements.Store

  @evidence_fields ~w(id state reason frozen_at posting_started_at message_posted_at thread_created_at concluded_at discord_message_id discord_thread_id error_detail thread_attempts last_thread_error applied_suppression_id applied_override_id)a

  def window(from, to, opts) do
    clock = clock(opts)

    with {:ok, dates} <- dates(from, to, clock.today, true) do
      announcements = Repo.all(from(a in Announcement, where: not a.retired))
      {:ok, build_window(announcements, dates.from, dates.to, clock, :all)}
    end
  end

  def get(announcement, date, opts) do
    clock = clock(opts)

    with {:ok, dates} <- dates(date, date, clock.today, false) do
      case build_window([announcement], dates.from, dates.to, clock, :none) do
        [item] -> {:ok, item}
        [] -> {:error, :not_found}
      end
    end
  end

  def list(announcement, params, opts) do
    clock = clock(opts)

    changeset =
      {%{direction: "upcoming", limit: 3}, %{direction: :string, limit: :integer}}
      |> Ecto.Changeset.cast(params, [:direction, :limit])
      |> Ecto.Changeset.validate_required([:direction, :limit])
      |> Ecto.Changeset.validate_inclusion(:direction, ["upcoming", "recent"])
      |> Ecto.Changeset.validate_number(:limit, greater_than: 0, less_than_or_equal_to: 50)

    with {:ok, %{direction: direction, limit: limit}} <-
           Ecto.Changeset.apply_action(changeset, :read) do
      # Upcoming also lists the Holiday Announcements this announcement
      # currently drives, so a card shows the bot's "no training" notice in
      # place of the skipped roll call. A one-off's day-before notice is sent
      # the day before its date. Recent stays occurrence evidence only:
      # holiday evidence is owned by its date, not the triggering announcement.
      {from, to, holidays} =
        if direction == "upcoming",
          do:
            {(announcement.one_off_date && Date.add(announcement.one_off_date, -1)) ||
               clock.today, announcement.one_off_date || Date.add(clock.today, limit * 7),
             {:driven_by, announcement.id}},
          else: {TrainingAnnouncements.retention_horizon(clock.today), clock.today, :none}

      items = build_window([announcement], from, to, clock, holidays)
      items = Enum.filter(items, &direction?(&1, direction, clock.now))
      items = if direction == "recent", do: Enum.reverse(items), else: items
      {:ok, Enum.take(items, limit)}
    end
  end

  defp direction?(%{delivery: delivery}, "recent", _) when not is_nil(delivery), do: true
  defp direction?(_, "recent", _), do: false
  defp direction?(%{post_time: nil}, "upcoming", _), do: false

  defp direction?(item, "upcoming", now),
    do: DateTime.compare(ClubCalendar.to_utc(item.date, item.post_time), now) == :gt

  defp clock(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    civil = DateTime.shift_zone!(now, ClubCalendar.zone(), Tz.TimeZoneDatabase)
    %{now: now, today: DateTime.to_date(civil), now_time: DateTime.to_time(civil)}
  end

  defp dates(from, to, today, bounded?) do
    changeset =
      {%{}, %{from: :date, to: :date}}
      |> Ecto.Changeset.cast(%{from: from, to: to}, [:from, :to])
      |> Ecto.Changeset.validate_required([:from, :to])

    with {:ok, dates} <- Ecto.Changeset.apply_action(changeset, :read) do
      cond do
        Date.compare(dates.from, TrainingAnnouncements.retention_horizon(today)) == :lt ->
          {:error, ["from is before the 400-day retention horizon"]}

        Date.compare(dates.to, dates.from) == :lt ->
          {:error, ["to must be on or after from"]}

        bounded? and Date.diff(dates.to, dates.from) >= 62 ->
          {:error, ["window must contain at most 62 Dublin dates"]}

        true ->
          {:ok, dates}
      end
    end
  end

  # `holidays` is `:all` (calendar), `:none` (inspector, recent) or
  # `{:driven_by, id}` (a card's upcoming posts).
  defp build_window(announcements, first, last, clock, holidays) do
    ids = Enum.map(announcements, & &1.id)
    rows = evidence(first, last, ids, holidays == :all)
    entries = announcements |> Enum.reject(& &1.retired) |> Store.entries()
    future_from = if Date.compare(first, clock.today) == :lt, do: clock.today, else: first

    projected =
      if Date.compare(future_from, last) == :gt do
        []
      else
        {:ok, holidays_in_view} = ClubCalendar.holidays_between(future_from, Date.add(last, 1))

        opts = [
          today: clock.today,
          now_time: clock.now_time,
          holidays: MapSet.new(holidays_in_view, & &1.date)
        ]

        occurrences = Enum.flat_map(entries, &project(&1, future_from, last, opts))

        notices = project_holidays(holidays_in_view, holidays, future_from, last, clock)

        occurrences ++ notices
      end

    # Project first, then overwrite by the durable identity, including today's rows.
    (projected ++ Enum.map(rows, &row_view/1))
    |> Map.new(&{identity(&1), &1})
    |> Map.values()
    |> Enum.sort_by(&{Date.to_gregorian_days(&1.date), time_key(&1.post_time), identity(&1)})
  end

  defp evidence(first, last, ids, false) do
    Repo.all(
      from(d in Evidence,
        where:
          d.announcement_id in ^ids and d.occurrence_date >= ^first and d.occurrence_date <= ^last
      )
    )
  end

  defp evidence(first, last, _ids, true) do
    next_first = Date.add(first, 1)
    next_last = Date.add(last, 1)

    # Global windows include retained evidence from retired announcements too.
    Repo.all(
      from(d in Evidence,
        where: d.occurrence_date >= ^first and d.occurrence_date <= ^last,
        or_where: d.phase == "same_day" and d.holiday_date >= ^first and d.holiday_date <= ^last,
        or_where:
          d.phase == "day_before" and d.holiday_date >= ^next_first and
            d.holiday_date <= ^next_last
      )
    )
  end

  defp project(entry, first, last, opts) do
    opts = Keyword.merge(opts, suppressions: entry.suppressions, overrides: entry.overrides)

    Occurrences.window(entry.announcement, first, last, opts)
    |> Enum.map(fn occurrence ->
      {copy, errors} =
        case Copy.render(occurrence, occurrence.date) do
          {:ok, copy} -> {copy, []}
          {:error, errors} -> {%{rendered_message: nil, thread_name: nil}, errors}
        end

      base("occurrence", occurrence.date)
      |> Map.merge(%{
        announcement_id: occurrence.announcement_id,
        applied_suppression_id: occurrence.applied_suppression_id,
        applied_override_id: occurrence.applied_override_id,
        kind: occurrence.kind,
        post_time: entry.announcement.post_time,
        outcome: to_string(occurrence.outcome),
        chain: Enum.map(occurrence.chain, &to_string/1),
        title_source: occurrence.title,
        message_source: occurrence.message,
        mention_everyone: occurrence.mention_everyone,
        render_errors: errors
      })
      |> Map.merge(copy |> Map.take([:rendered_message, :thread_name]))
    end)
  end

  defp project_holidays(_holidays, :none, _first, _last, _clock), do: []

  defp project_holidays(holidays, scope, first, last, clock) do
    Enum.flat_map(holidays, fn holiday ->
      holiday.date
      |> HolidayAnnouncements.eligible()
      |> driven_by(scope)
      |> then(&project_holiday(holiday, &1, first, last, clock))
    end)
  end

  defp driven_by(announcement, :all), do: announcement
  defp driven_by(%{id: id} = announcement, {:driven_by, id}), do: announcement
  defp driven_by(_announcement, {:driven_by, _id}), do: nil

  defp project_holiday(_holiday, nil, _first, _last, _clock), do: []

  defp project_holiday(holiday, announcement, first, last, clock) do
    for phase <- ["day_before", "same_day"],
        date = HolidayAnnouncements.send_date(holiday.date, phase),
        Date.compare(date, first) != :lt,
        Date.compare(date, last) != :gt,
        DateTime.compare(ClubCalendar.to_utc(date, announcement.post_time), clock.now) ==
          :gt do
      base("holiday", date)
      |> Map.merge(%{
        holiday_date: holiday.date,
        phase: phase,
        post_time: announcement.post_time,
        mention_everyone: true,
        outcome: "post",
        chain: ["holiday"]
      })
      |> Map.merge(holiday_copy(holiday, phase))
    end
  end

  defp holiday_copy(holiday, phase) do
    case HolidayAnnouncements.preview(holiday, phase) do
      {:ok, copy} -> copy
      {:error, errors} -> %{render_errors: errors}
    end
  end

  defp row_view(row) do
    date = row.occurrence_date || HolidayAnnouncements.send_date(row.holiday_date, row.phase)

    base(row.subject, date)
    |> Map.merge(
      Map.take(row, [
        :announcement_id,
        :holiday_date,
        :phase,
        :post_time,
        :kind,
        :title_source,
        :message_source,
        :mention_everyone,
        :rendered_message,
        :thread_name,
        :applied_suppression_id,
        :applied_override_id
      ])
    )
    |> Map.merge(%{
      outcome: row.resolved_outcome || legacy_outcome(row),
      chain: row.precedence_chain,
      delivery: row |> Map.take(@evidence_fields) |> Map.put(:permalink, permalink(row))
    })
  end

  defp legacy_outcome(%{state: "skipped", reason: "holiday"}), do: "skipped_holiday"
  defp legacy_outcome(%{state: "skipped", reason: "disabled"}), do: "skipped_disabled"
  defp legacy_outcome(%{state: "skipped", reason: "suppressed"}), do: "skipped_suppressed"
  defp legacy_outcome(%{state: "missed"}), do: "missed"
  defp legacy_outcome(_), do: "unknown"

  defp permalink(row) do
    guild = Application.get_env(:dhc, :discord_guild_id)

    if guild && row.channel_id && row.discord_message_id,
      do: "https://discord.com/channels/#{guild}/#{row.channel_id}/#{row.discord_message_id}",
      else: nil
  end

  defp base(subject, date) do
    %{
      subject: subject,
      date: date,
      announcement_id: nil,
      holiday_date: nil,
      phase: nil,
      post_time: nil,
      kind: nil,
      outcome: "unknown",
      chain: [],
      title_source: nil,
      message_source: nil,
      mention_everyone: nil,
      rendered_message: nil,
      thread_name: nil,
      read_only: subject == "holiday",
      render_errors: [],
      delivery: nil,
      applied_suppression_id: nil,
      applied_override_id: nil
    }
  end

  defp identity(%{subject: "occurrence"} = item),
    do: {item.subject, item.announcement_id, item.date}

  defp identity(item), do: {item.subject, item.holiday_date, item.phase}
  defp time_key(nil), do: -1
  defp time_key(time), do: Time.diff(time, ~T[00:00:00])
end
