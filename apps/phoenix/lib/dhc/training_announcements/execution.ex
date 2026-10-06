defmodule Dhc.TrainingAnnouncements.Execution do
  @moduledoc """
  Turns one due Announcement Occurrence or Holiday Announcement into its
  Discord Announcement Delivery evidence (ALE-348, ADR 0026).

  `evaluate/2,3` (the optional third argument is the driving job) is the
  only path from a due reference to a durable row:

    1. An existing Evidence row always wins (a replay never writes a second
       row and never re-resolves the occurrence).
    2. Otherwise it claims the Training Announcement through
       `Store.with_current/2`, resolves the date in due mode
       (`Occurrences.resolve_due/3`), checks copy (`Copy`) and channel
       (`Channels`), and writes exactly one row — frozen, skipped, missed or
       pre-freeze blocked — through the one private writer, in the same
       transaction as the next driver or holiday-recovery job that
       `Scheduling` writes.
    3. After commit it hands the row to `Delivery.progress/3`.

  Callers never choose a resolver, and workers only translate job arguments
  into an `evaluate` call.

  `clock/0,1,2` is the one Training Announcement clock: Dublin `today`,
  Dublin `now_time` (both from `Dhc.ClubCalendar`) and the bank-holiday set,
  loaded before any write transaction (a fetch-on-miss may use HTTP). Time
  is read again inside each claim, so a claim that waited decides
  missed/not-yet-due and stamps `frozen_at`/`first_attempted_at` with the
  instant it holds the row; a fixed clock reads the same instant every
  time. The read model (`OccurrenceReads`) builds the same clock.
  """
  import Ecto.Query

  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements.Channels
  alias Dhc.TrainingAnnouncements.Copy
  alias Dhc.TrainingAnnouncements.Delivery
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence
  alias Dhc.TrainingAnnouncements.HolidayAnnouncements
  alias Dhc.TrainingAnnouncements.Occurrences
  alias Dhc.TrainingAnnouncements.Scheduling
  alias Dhc.TrainingAnnouncements.Store

  @phases ["day_before", "same_day"]

  # Covers today, tomorrow's day-before notice and the next weekly driver
  # (`Scheduling.next_date/3` looks at most eight days ahead).
  @due_horizon_days 8

  # Oban's default budget; callers outside a job get a first attempt.
  @default_job %{attempt: 1, max_attempts: 20}

  @type ref :: {:announcement, Ecto.UUID.t(), Date.t()} | {:holiday, String.t(), Date.t()}

  @type clock :: %{
          now: DateTime.t(),
          today: Date.t(),
          now_time: Time.t(),
          from: Date.t(),
          through: Date.t(),
          holidays: %{Date.t() => Holiday.t()},
          tick: (-> DateTime.t())
        }

  @doc """
  The live clock: every reading (each claim, each Discord checkpoint) is
  the current instant. Holidays cover today through eight days ahead.
  """
  @spec clock() :: clock()
  def clock do
    clock = new_clock(DateTime.utc_now(), &DateTime.utc_now/0)
    load_holidays(clock, Date.add(clock.today, @due_horizon_days))
  end

  @doc """
  A clock fixed at `now`, for tests and reads: every reading is `now`.
  Option `:through` sets the last Dublin date of the holiday set (default
  eight days after today); `through: nil` loads none, for a caller that
  first needs `today` to choose its range (then `load_holidays/2`).
  """
  @spec clock(DateTime.t(), keyword()) :: clock()
  def clock(%DateTime{} = now, opts \\ []) do
    clock = new_clock(now, fn -> now end)

    case Keyword.get(opts, :through, Date.add(clock.today, @due_horizon_days)) do
      nil -> clock
      through -> load_holidays(clock, through)
    end
  end

  defp new_clock(now, tick),
    do: Map.merge(%{from: nil, through: nil, holidays: %{}, tick: tick}, reading_at(now))

  # Today and civil time always come from ClubCalendar (ADR 0026).
  defp reading_at(now),
    do: %{now: now, today: ClubCalendar.on_date(now), now_time: ClubCalendar.time_on(now)}

  @doc """
  Loads the bank holidays from the clock's today through `through`
  (inclusive), replacing any loaded set. A fetch-on-miss may use HTTP, so
  call it before any write transaction.
  """
  @spec load_holidays(clock(), Date.t()) :: clock()
  def load_holidays(clock, %Date{} = through) do
    holidays =
      if Date.compare(through, clock.today) == :lt do
        %{}
      else
        {:ok, holidays} = ClubCalendar.holidays_between(clock.today, through)
        Map.new(holidays, &{&1.date, &1})
      end

    %{clock | from: clock.today, through: through, holidays: holidays}
  end

  # A fresh reading taken inside the claim: time-dependent decisions and
  # stamps must not use an instant from before a claim that waited.
  defp read(clock), do: Map.merge(clock, reading_at(clock.tick.()))

  @doc "The clock's bank holidays in the inclusive range, ordered by date."
  @spec holidays_between(clock(), Date.t(), Date.t()) :: [Holiday.t()]
  def holidays_between(clock, %Date{} = from, %Date{} = to) do
    clock.holidays
    |> Map.values()
    |> Enum.filter(&(Date.compare(&1.date, from) != :lt and Date.compare(&1.date, to) != :gt))
    |> Enum.sort_by(& &1.date, Date)
  end

  # A date outside the loaded window (a stale driver) reads the committed
  # cache only: no HTTP inside a write transaction.
  defp holiday_on(%{from: from, through: through} = clock, date)
       when not is_nil(from) and not is_nil(through) do
    if Date.compare(date, from) != :lt and Date.compare(date, through) != :gt,
      do: Map.get(clock.holidays, date),
      else: ClubCalendar.cached_holiday_on(date)
  end

  defp holiday_on(_clock, date), do: ClubCalendar.cached_holiday_on(date)

  @doc """
  Evaluates a due reference and progresses its Evidence. Returns an Oban
  result (`:ok`, `{:error, reason}` for a retryable deferral, or
  `{:snooze, seconds}`). The optional `job` carries the driver's `attempt`
  and `max_attempts`, which reserve the last attempt for local
  terminalization; workers pass their `Oban.Job`.
  """
  @spec evaluate(ref(), clock(), map()) :: :ok | {:error, term()} | {:snooze, pos_integer()}
  def evaluate(ref, clock, job \\ @default_job)

  def evaluate({:announcement, id, %Date{} = date}, clock, job) do
    case Store.with_current(id, &claim_occurrence(&1, date, read(clock))) do
      {:ok, {:existing, evidence}} -> progress(evidence, job, clock)
      {:ok, {:written, evidence}} -> report_and_progress(evidence, job, clock)
      {:ok, nil} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def evaluate({:holiday, phase, %Date{} = date}, clock, job) when phase in @phases do
    case evidence_for({:holiday, phase, date}) do
      nil -> claim_holiday(phase, date, clock, job, 3)
      evidence -> progress(evidence, job, clock)
    end
  end

  defp report_and_progress(evidence, job, clock) do
    Delivery.report_failure(evidence)
    progress(evidence, job, clock)
  end

  # A roll call skipped for a bank holiday drives that day's reminder.
  defp progress(
         %{subject: "occurrence", state: "skipped", reason: "holiday", occurrence_date: date},
         job,
         clock
       ),
       do: evaluate({:holiday, "same_day", date}, clock, job)

  defp progress(evidence, job, clock), do: Delivery.progress(evidence, job, clock.tick)

  ## Announcement Occurrences

  # `clock` is the reading taken inside the claim.
  defp claim_occurrence(announcement, date, clock) do
    case evidence_for({:announcement, announcement.id, date}) do
      nil -> decide_occurrence(announcement, date, clock)
      evidence -> {:existing, evidence}
    end
  end

  defp decide_occurrence(%{retired: true}, _date, _clock), do: nil

  defp decide_occurrence(announcement, date, clock) do
    entry = Store.entry(announcement)

    occurrence =
      Occurrences.resolve_due(announcement, date,
        suppressions: entry.suppressions,
        overrides: entry.overrides,
        holidays: holiday_dates(clock, date)
      )

    cond do
      is_nil(occurrence) ->
        # An edited schedule already owns a replacement driver. A stale job
        # must not move that new pending occurrence past its own obsolete date.
        nil

      DateTime.compare(ClubCalendar.to_utc(date, announcement.post_time), clock.now) == :gt ->
        # Complete this driver rather than snoozing into a second pending job
        # after a same-date time edit. Ensure the one future driver.
        enqueue_next!(announcement, clock.now, nil)
        nil

      true ->
        evidence =
          write(
            %{
              subject: "occurrence",
              announcement_id: announcement.id,
              occurrence_date: occurrence.date,
              applied_suppression_id: occurrence.applied_suppression_id,
              applied_override_id: occurrence.applied_override_id,
              resolved_outcome: to_string(occurrence.outcome),
              precedence_chain: Enum.map(occurrence.chain, &to_string/1)
            },
            occurrence_snapshot(announcement, occurrence, clock),
            clock
          )

        if evidence, do: stamp_first_attempt(announcement, evidence, clock)
        enqueue_next!(announcement, clock.now, occurrence.date)
        evidence && {:written, evidence}
    end
  end

  defp holiday_dates(clock, date) do
    if holiday_on(clock, date), do: MapSet.new([date]), else: MapSet.new()
  end

  defp stamp_first_attempt(%{first_attempted_at: nil} = announcement, %{state: "frozen"}, clock) do
    announcement |> Ecto.Changeset.change(first_attempted_at: clock.now) |> Repo.update!()
  end

  defp stamp_first_attempt(_announcement, _evidence, _clock), do: :ok

  defp enqueue_next!(announcement, now, date) do
    _job = Store.persist!(Scheduling.enqueue_next(announcement, now, date))
    :ok
  end

  defp occurrence_snapshot(announcement, occurrence, clock) do
    cond do
      Date.compare(occurrence.date, clock.today) == :lt -> missed(clock, precedence_chain: [])
      occurrence.outcome == :skipped_holiday -> concluded("skipped", "holiday", clock)
      occurrence.outcome == :skipped_disabled -> concluded("skipped", "disabled", clock)
      occurrence.outcome == :skipped_suppressed -> concluded("skipped", "suppressed", clock)
      true -> freeze_occurrence(announcement, occurrence, clock)
    end
  end

  defp freeze_occurrence(announcement, occurrence, clock) do
    with {:ok, channel} <- Channels.for_kind(occurrence.kind),
         {:ok, copy} <- Copy.render(occurrence, occurrence.date) do
      frozen(channel, announcement.post_time, clock, %{
        kind: occurrence.kind,
        mention_everyone: occurrence.mention_everyone,
        title_source: occurrence.title,
        message_source: occurrence.message,
        rendered_message: copy.rendered_message,
        thread_name: copy.thread_name
      })
    else
      error -> blocked(error, clock)
    end
  end

  ## Holiday Announcements

  defp claim_holiday(phase, date, clock, job, retries) do
    with %Holiday{} <- holiday_on(clock, date),
         %{} = announcement <- HolidayAnnouncements.eligible(date) do
      case Store.with_current(announcement.id, &decide_holiday(&1, date, phase, read(clock))) do
        {:ok, :reselect} when retries > 0 ->
          claim_holiday(phase, date, clock, job, retries - 1)

        {:ok, :reselect} ->
          {:error, :concurrent_change}

        {:ok, {:written, evidence}} ->
          report_and_progress(evidence, job, clock)

        {:ok, {:snooze, _seconds} = snooze} ->
          snooze

        {:ok, nil} ->
          :ok

        {:error, :not_found} when retries > 0 ->
          claim_holiday(phase, date, clock, job, retries - 1)

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> :ok
    end
  end

  # `clock` is the reading taken inside the claim.
  defp decide_holiday(announcement, date, phase, clock) do
    # Re-read the committed cache under the claim: a refresh may have
    # removed the date since the clock was built.
    with true <- driver?(announcement),
         %{} <- Occurrences.resolve_due(announcement, date, []),
         %Holiday{} = holiday <- ClubCalendar.cached_holiday_on(date) do
      at =
        ClubCalendar.to_utc(HolidayAnnouncements.send_date(date, phase), announcement.post_time)

      if DateTime.compare(at, clock.now) == :gt,
        do: {:snooze, max(1, DateTime.diff(at, clock.now, :second))},
        else: write_holiday(holiday, phase, announcement.post_time, clock)
    else
      _ -> :reselect
    end
  end

  defp driver?(announcement),
    do: announcement.enabled and not announcement.retired and announcement.kind == "roll_call"

  defp write_holiday(holiday, phase, post_time, clock) do
    evidence =
      write(
        %{
          subject: "holiday",
          holiday_date: holiday.date,
          phase: phase,
          resolved_outcome: "post",
          precedence_chain: ["holiday"]
        },
        holiday_snapshot(holiday, phase, post_time, clock),
        clock
      )

    if evidence, do: enqueue_recovery!(evidence, clock)
    evidence && {:written, evidence}
  end

  # Commit this independent recovery driver with a same-day holiday freeze.
  # Deleting/retiring its triggering roll call must not abandon frozen evidence.
  defp enqueue_recovery!(%{state: "frozen", phase: "same_day", holiday_date: date}, clock) do
    _job = Store.persist!(Scheduling.enqueue_holiday_recovery(date, clock.now))
    :ok
  end

  defp enqueue_recovery!(_evidence, _clock), do: :ok

  defp holiday_snapshot(holiday, phase, post_time, clock) do
    if Date.compare(HolidayAnnouncements.send_date(holiday.date, phase), clock.today) == :lt do
      missed(clock)
    else
      with {:ok, channel} <- Channels.for_kind("holiday"),
           {:ok, copy} <- HolidayAnnouncements.preview(holiday, phase) do
        frozen(channel, post_time, clock, %{
          mention_everyone: true,
          message_source: copy.message_source,
          rendered_message: copy.rendered_message
        })
      else
        error -> blocked(error, clock)
      end
    end
  end

  ## Shared evidence snapshots

  defp frozen(channel, post_time, clock, copy),
    do:
      Map.merge(copy, %{
        state: "frozen",
        frozen_at: clock.now,
        post_time: post_time,
        channel_id: channel
      })

  defp missed(clock, extra \\ []),
    do:
      Map.merge(
        concluded("missed", "late", clock),
        Map.new([{:resolved_outcome, "missed"} | extra])
      )

  defp concluded(state, reason, clock),
    do: %{state: state, reason: reason, concluded_at: clock.now}

  defp blocked({:error, :unconfigured_channel}, clock),
    do: concluded("blocked", "unconfigured_channel", clock)

  defp blocked({:error, _errors}, clock), do: concluded("blocked", "invalid_copy", clock)

  defp evidence_for({:announcement, id, date}) do
    Repo.one(from(d in Evidence, where: d.announcement_id == ^id and d.occurrence_date == ^date))
  end

  defp evidence_for({:holiday, phase, date}) do
    Repo.one(from(d in Evidence, where: d.holiday_date == ^date and d.phase == ^phase))
  end

  # The one Evidence writer: an identity, a snapshot that may override its
  # resolution (a missed row), and the claim's reading. Row uniqueness is
  # the durable duplicate fence: a lost race inserts nothing and returns nil.
  defp write(identity, snapshot, clock) do
    attrs =
      %{id: Ecto.UUID.generate(), created_at: clock.now, updated_at: clock.now}
      |> Map.merge(identity)
      |> Map.merge(snapshot)

    case Repo.insert_all(Evidence, [attrs], on_conflict: :nothing, returning: true) do
      {1, [evidence]} -> evidence
      {0, []} -> nil
    end
  end
end
