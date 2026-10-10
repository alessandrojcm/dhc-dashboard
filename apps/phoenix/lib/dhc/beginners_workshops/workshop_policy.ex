defmodule Dhc.BeginnersWorkshops.WorkshopPolicy do
  @moduledoc """
  Pure predicates and derivations for one Beginners' Workshop, shared by the
  boundary (`Dhc.BeginnersWorkshops.Commands`, deciding under the lock) and
  the read models (advising without one) — the `Dhc.Inventory.LoanPolicy`
  precedent. Nothing here reads the database or the clock; callers pass a
  `Dhc.BeginnersWorkshops.Clock` reading and the workshop's
  `Dhc.BeginnersWorkshops.WorkshopFacts`.
  """

  alias Dhc.BeginnersWorkshops.BeginnersWorkshop
  alias Dhc.ClubCalendar

  @default_cutoff_days 3
  @default_payment_window_days 7
  # Batches go out at 10:00 Dublin time (spec: automatic Batches).
  @batch_time ~T[10:00:00]
  # A Batch window ends at 23:59 Dublin time (stored as the last instant of
  # the minute, so no Batch can go out between 23:59 and midnight).
  @window_end_time ~T[23:59:59.999999]
  @check_in_lead_minutes 60
  # The Follow-up goes out at 10:00 Dublin the morning after (ALE-391).
  @follow_up_time ~T[10:00:00]
  # A Seat Hold keeps a seat for 30 minutes of checkout (ALE-381).
  @hold_minutes 30

  @type stage ::
          :before_contact_from
          | :window_open
          | :next_batch_due
          | :batches_paused
          | :full
          | :payment_closed
          | :today_before_check_in
          | :check_in_open
          | :awaiting_finalisation
          | :finalised
          | :cancelled

  @type alert :: :unstaffed

  @stages ~w(before_contact_from window_open next_batch_due batches_paused full payment_closed today_before_check_in check_in_open awaiting_finalisation finalised cancelled)a
  @alerts ~w(unstaffed)a

  @doc "Every stage, in lifecycle order."
  @spec stages() :: [stage()]
  def stages, do: @stages

  @doc "Every alert."
  @spec alerts() :: [alert()]
  def alerts, do: @alerts

  @doc "The default payment window length in days."
  @spec default_payment_window_days() :: pos_integer()
  def default_payment_window_days, do: @default_payment_window_days

  @doc "The Dublin date of the default Payment Cutoff: 3 days before the start."
  @spec default_cutoff_date(Date.t()) :: Date.t()
  def default_cutoff_date(%Date{} = date), do: Date.add(date, -@default_cutoff_days)

  @doc "The instant the workshop starts."
  @spec starts_at(BeginnersWorkshop.t() | %{date: Date.t(), start_time: Time.t()}) ::
          DateTime.t()
  def starts_at(%{date: date, start_time: time}), do: ClubCalendar.to_utc(date, time)

  @doc "Whether `cutoff` is strictly before the start (the Payment Cutoff rule)."
  @spec cutoff_before_start?(DateTime.t(), DateTime.t()) :: boolean()
  def cutoff_before_start?(cutoff, starts_at), do: DateTime.compare(cutoff, starts_at) == :lt

  @doc "Whether the contact-from date is on or before the cutoff's Dublin date."
  @spec contact_from_valid?(Date.t(), DateTime.t()) :: boolean()
  def contact_from_valid?(%Date{} = contact_from, cutoff),
    do: Date.compare(contact_from, ClubCalendar.on_date(cutoff)) != :gt

  @doc "Whether the contact-from date can still change: until Batch 1 has gone out."
  @spec contact_from_editable?(map()) :: boolean()
  def contact_from_editable?(%{batches_sent: sent}), do: sent == 0

  @doc """
  ALE-394: the Payment Cutoff a rescheduled workshop keeps — the same Dublin
  civil offset before its new start (`next`'s `date` and `start_time`) as the
  current cutoff had before the current start. Civil, so a move across a
  clock change keeps "3 days before at the start time".
  """
  @spec kept_offset_cutoff(BeginnersWorkshop.t(), %{date: Date.t(), start_time: Time.t()}) ::
          DateTime.t()
  def kept_offset_cutoff(%BeginnersWorkshop{} = workshop, %{date: date, start_time: start_time}) do
    current_cutoff =
      NaiveDateTime.new!(
        ClubCalendar.on_date(workshop.payment_cutoff),
        ClubCalendar.time_on(workshop.payment_cutoff)
      )

    offset =
      workshop.date
      |> NaiveDateTime.new!(workshop.start_time)
      |> NaiveDateTime.diff(current_cutoff, :microsecond)

    kept = date |> NaiveDateTime.new!(start_time) |> NaiveDateTime.add(-offset, :microsecond)
    ClubCalendar.to_utc(NaiveDateTime.to_date(kept), NaiveDateTime.to_time(kept))
  end

  @doc """
  ALE-394: the contact-from date a rescheduled workshop keeps while Batch 1
  has not gone out — the same number of days before the new date — or Dublin
  today when that would fall after the new cutoff date, so Batch 1 goes out
  at the next 10:00. It is never after the cutoff date (the
  `:invalid_contact_from` rule): when today already is, it stops there.
  """
  @spec kept_contact_from(BeginnersWorkshop.t(), Date.t(), DateTime.t(), map()) :: Date.t()
  def kept_contact_from(%BeginnersWorkshop{} = workshop, %Date{} = date, cutoff, reading) do
    kept = Date.add(date, -Date.diff(workshop.date, workshop.contact_from))

    if contact_from_valid?(kept, cutoff),
      do: kept,
      else: Enum.min([reading.today, ClubCalendar.on_date(cutoff)], Date)
  end

  @doc "Whether the fee can still change: until the first Intake exists (`:fee_locked`)."
  @spec fee_editable?(map()) :: boolean()
  def fee_editable?(%{intakes: intakes}), do: intakes == 0

  @doc "The size of the next Batch: capacity − Intakes already paid (holds are not subtracted)."
  @spec batch_size(BeginnersWorkshop.t(), map()) :: non_neg_integer()
  def batch_size(%BeginnersWorkshop{capacity: capacity}, %{paid: paid}),
    do: max(capacity - paid, 0)

  @doc """
  Whether the workshop's next Batch is due at `reading`, apart from whether
  anyone eligible is waiting (the boundary reads the Waitlist under the
  lock): the workshop is scheduled and not paused, Dublin today is on or
  after the contact-from date and it is 10:00 or later, no Batch window is
  open, it is before the Payment Cutoff and capacity − paid is above zero.
  """
  @spec batch_due?(BeginnersWorkshop.t(), map(), map()) :: boolean()
  def batch_due?(%BeginnersWorkshop{status: "scheduled"} = workshop, facts, reading) do
    not facts.batches_paused and
      Date.compare(reading.today, workshop.contact_from) != :lt and
      Time.compare(reading.now_time, @batch_time) != :lt and
      not window_open?(facts, reading) and
      DateTime.compare(reading.now, workshop.payment_cutoff) == :lt and
      batch_size(workshop, facts) > 0
  end

  def batch_due?(%BeginnersWorkshop{}, _facts, _reading), do: false

  @doc """
  When a Batch sent at `reading` closes its payment window: 23:59 Dublin
  time, window-length days after the send date — or the Payment Cutoff
  itself when that date is on or after the cutoff date.
  """
  @spec window_end(BeginnersWorkshop.t(), map()) :: DateTime.t()
  def window_end(%BeginnersWorkshop{} = workshop, reading) do
    end_date = Date.add(reading.today, workshop.payment_window_days)

    if Date.compare(end_date, ClubCalendar.on_date(workshop.payment_cutoff)) == :lt,
      do: ClubCalendar.to_utc(end_date, @window_end_time),
      else: workshop.payment_cutoff
  end

  @doc """
  Whether a scheduled workshop still takes new Stripe payers at `reading`:
  before its Payment Cutoff. `fast_track` (ALE-384) and a new Seat Hold
  (`start_payment`, ALE-381) are refused after it, and
  the console offers Fast-track only while it holds; the Carried Fee holder
  exception joins this rule with the defer-and-confirm ticket.
  """
  @spec payment_open?(BeginnersWorkshop.t(), map()) :: boolean()
  def payment_open?(%BeginnersWorkshop{status: "scheduled", payment_cutoff: cutoff}, reading),
    do: DateTime.compare(reading.now, cutoff) == :lt

  def payment_open?(%BeginnersWorkshop{}, _reading), do: false

  @typedoc """
  When the next Batch goes out: `:due` (at the next sweep), `{:at, instant}`,
  `:paused`, `:full` (no unpaid seats; it goes as soon as a seat frees) or
  `:closed` (no further Batch can go before the Payment Cutoff).
  """
  @type next_batch :: :due | {:at, DateTime.t()} | :paused | :full | :closed

  @doc "When the workshop's next Batch goes out, judged at `reading`."
  @spec next_batch(BeginnersWorkshop.t(), map(), map()) :: next_batch()
  def next_batch(%BeginnersWorkshop{} = workshop, facts, reading) do
    cond do
      workshop.status != "scheduled" -> :closed
      DateTime.compare(reading.now, workshop.payment_cutoff) != :lt -> :closed
      batch_size(workshop, facts) == 0 -> :full
      facts.batches_paused -> :paused
      batch_due?(workshop, facts, reading) -> :due
      true -> next_slot(workshop, facts, reading)
    end
  end

  # The first 10:00 Dublin at or after the latest of: 10:00 on the
  # contact-from date, the end of the open window, and now.
  defp next_slot(workshop, facts, reading) do
    earliest =
      [
        ClubCalendar.to_utc(workshop.contact_from, @batch_time),
        facts.latest_window_end,
        reading.now
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime)

    day = ClubCalendar.on_date(earliest)
    same_day = ClubCalendar.to_utc(day, @batch_time)

    at =
      if DateTime.compare(earliest, same_day) == :gt,
        do: ClubCalendar.to_utc(Date.add(day, 1), @batch_time),
        else: same_day

    if DateTime.compare(at, workshop.payment_cutoff) == :lt, do: {:at, at}, else: :closed
  end

  @refund_hint_days 7

  @doc """
  ALE-387 (story 77): the refund-timing hint for choosing between keeping a
  fee and refunding it — the whole Dublin days left until a scheduled
  workshop's date while that is #{@refund_hint_days} or fewer (0 on the day),
  `nil` otherwise. There is no deadline; it only says how close the
  workshop is, judged on the boundary clock.
  """
  @spec refund_hint_days(BeginnersWorkshop.t(), map()) :: non_neg_integer() | nil
  def refund_hint_days(%BeginnersWorkshop{status: "scheduled", date: date}, reading) do
    days = Date.diff(date, reading.today)
    if days in 0..@refund_hint_days//1, do: days
  end

  def refund_hint_days(%BeginnersWorkshop{}, _reading), do: nil

  @doc "Whether a person born on `date_of_birth` is a minor (under 18) on the workshop date."
  @spec minor?(Date.t() | nil, Date.t()) :: boolean()
  def minor?(nil, _workshop_date), do: false

  def minor?(%Date{} = date_of_birth, %Date{} = workshop_date) do
    eighteenth =
      case Date.new(date_of_birth.year + 18, date_of_birth.month, date_of_birth.day) do
        {:ok, date} -> date
        # Born on 29 February: an adult from 1 March.
        {:error, _} -> Date.new!(date_of_birth.year + 18, 3, 1)
      end

    Date.compare(workshop_date, eighteenth) == :lt
  end

  @typedoc """
  What the Payment Cutoff pass does with one `contacted` Intake:
  `:await_hold` (leave it until Stripe ends its live Seat Hold), `:lapse`
  (seats were free: the person is removed) or `:return` (the workshop was
  full: back to the Waitlist with the original priority).
  """
  @type cutoff_settlement :: :await_hold | :lapse | :return

  @doc """
  The Payment Cutoff rule for one `contacted` Intake (ALE-385, stories
  86–87), judged under the workshop lock after the cutoff.

  The cutoff stops only *new* Seat Holds, so an Intake whose own hold is
  still live (an `open` payment row, even one past its 30 minutes that
  Stripe has not ended) is left alone: if Stripe completes it the Intake
  becomes `paid`, otherwise a later sweep settles it by this same rule. An
  Intake without a live hold lapses when a seat is free (`seat_free?/2`:
  capacity − paid − live holds > 0) and returns when the workshop is full —
  a person who could only ever see "full" is never removed.

  Seats are judged when the pass runs (the first sweep after the cutoff,
  within minutes), not replayed as at the cutoff instant.

  This is the assembly-time reading of the spec; it is the one place to
  change if the club reads a hold live at the cutoff differently.
  """
  @spec cutoff_settlement(hold_live? :: boolean(), BeginnersWorkshop.t(), map()) ::
          cutoff_settlement()
  def cutoff_settlement(true, _workshop, _facts), do: :await_hold

  def cutoff_settlement(false, %BeginnersWorkshop{} = workshop, facts),
    do: if(seat_free?(workshop, facts), do: :lapse, else: :return)

  @doc "When a Seat Hold taken at `reading` runs out (the reaper then asks Stripe to expire it)."
  @spec hold_expires_at(map()) :: DateTime.t()
  def hold_expires_at(%{now: now}), do: DateTime.add(now, @hold_minutes * 60, :second)

  @doc "Seats taken: Intakes in `paid` + payment rows in `open` (live Seat Holds)."
  @spec seats_taken(map()) :: non_neg_integer()
  def seats_taken(%{paid: paid, holds: holds}), do: paid + holds

  @doc "Whether a new Seat Hold (or a Carried Fee confirm) can take a seat."
  @spec seat_free?(BeginnersWorkshop.t(), map()) :: boolean()
  def seat_free?(%BeginnersWorkshop{capacity: capacity}, facts),
    do: capacity - seats_taken(facts) > 0

  @doc "Whether `capacity` may replace the current one: never below the seats taken."
  @spec capacity_allowed?(integer(), map()) :: boolean()
  def capacity_allowed?(capacity, facts) when is_integer(capacity),
    do: capacity >= seats_taken(facts)

  @doc """
  Seats: capacity, paid, live holds and free (never negative), and the
  attendance outcome — `attended` and `no_show` — which is zero until
  Attendance Finalisation.
  """
  @spec seats(BeginnersWorkshop.t(), map()) :: %{
          capacity: pos_integer(),
          paid: non_neg_integer(),
          holds: non_neg_integer(),
          free: non_neg_integer(),
          attended: non_neg_integer(),
          no_show: non_neg_integer()
        }
  def seats(%BeginnersWorkshop{capacity: capacity}, %{paid: paid, holds: holds} = facts) do
    %{
      capacity: capacity,
      paid: paid,
      holds: holds,
      free: max(capacity - paid - holds, 0),
      attended: Map.get(facts, :attended, 0),
      no_show: Map.get(facts, :no_show, 0)
    }
  end

  @doc """
  The workshop's current stage at `reading`. A scheduled workshop is judged
  day-of first (check-in, today, past), then payment (cutoff, `full` when
  every seat is paid or held), then Batch timing.
  """
  @spec stage(BeginnersWorkshop.t(), map(), map()) :: stage()
  def stage(%BeginnersWorkshop{status: "cancelled"}, _facts, _reading), do: :cancelled
  def stage(%BeginnersWorkshop{status: "finalised"}, _facts, _reading), do: :finalised

  def stage(%BeginnersWorkshop{status: "scheduled"} = workshop, facts, reading) do
    case Date.compare(reading.today, workshop.date) do
      :eq ->
        if check_in_open?(workshop, reading), do: :check_in_open, else: :today_before_check_in

      :gt ->
        :awaiting_finalisation

      :lt ->
        before_the_day(workshop, facts, reading)
    end
  end

  defp before_the_day(workshop, facts, reading) do
    cond do
      DateTime.compare(reading.now, workshop.payment_cutoff) != :lt -> :payment_closed
      not seat_free?(workshop, facts) -> :full
      facts.batches_paused -> :batches_paused
      window_open?(facts, reading) -> :window_open
      before_first_batch?(workshop, facts, reading) -> :before_contact_from
      true -> :next_batch_due
    end
  end

  @doc """
  What needs the coordinator's attention on a scheduled workshop:
  `:unstaffed` while nobody at all — neither a coach nor an assistant — is
  on its Staff (story 15).
  """
  @spec alerts(BeginnersWorkshop.t(), map()) :: [alert()]
  def alerts(%BeginnersWorkshop{status: "scheduled"}, %{staff: staff}) do
    if staff.coach == nil and staff.assistants == [], do: [:unstaffed], else: []
  end

  def alerts(%BeginnersWorkshop{}, _facts), do: []

  defp check_in_open?(workshop, reading),
    do: DateTime.compare(reading.now, check_in_opens_at(workshop)) != :lt

  @doc "When door check-in opens: 1 hour before the start (Dublin) on the workshop date."
  @spec check_in_opens_at(BeginnersWorkshop.t() | %{date: Date.t(), start_time: Time.t()}) ::
          DateTime.t()
  def check_in_opens_at(workshop),
    do: DateTime.add(starts_at(workshop), -@check_in_lead_minutes * 60, :second)

  @typedoc "Where `reading` falls against the door check-in window."
  @type check_in_window :: :before | :open | :closed

  @doc """
  The door check-in window at `reading` (spec stories 91–92): `:open` from
  1 hour before the start on the workshop date until Attendance
  Finalisation or the end of that Dublin day, whichever comes first;
  `:before` while it has not opened; `:closed` once it has ended (or the
  workshop is finalised or cancelled). `check_in` and `undo_check_in`
  work only while it is `:open`.
  """
  @spec check_in_window(BeginnersWorkshop.t(), map()) :: check_in_window()
  def check_in_window(%BeginnersWorkshop{status: "scheduled"} = workshop, reading) do
    case Date.compare(reading.today, workshop.date) do
      :lt -> :before
      :gt -> :closed
      :eq -> if check_in_open?(workshop, reading), do: :open, else: :before
    end
  end

  def check_in_window(%BeginnersWorkshop{}, _reading), do: :closed

  @doc """
  Whether Staff may press Finish (`finish_workshop`, story 95) at
  `reading`: a scheduled workshop whose check-in window has opened — on the
  day, or after it while the automatic pass has not run yet.
  """
  @spec finish_allowed?(BeginnersWorkshop.t(), map()) :: boolean()
  def finish_allowed?(%BeginnersWorkshop{status: "scheduled"} = workshop, reading),
    do: check_in_window(workshop, reading) != :before

  def finish_allowed?(%BeginnersWorkshop{}, _reading), do: false

  @doc """
  Whether the automatic Attendance Finalisation (`finalise_attendance`,
  story 96) is due at `reading`: a scheduled workshop whose Dublin date has
  ended. Judged on Dublin dates, so the end of the day is midnight Dublin
  time whether that is 23:00Z (summer time) or 00:00Z.
  """
  @spec finalisation_due?(BeginnersWorkshop.t(), map()) :: boolean()
  def finalisation_due?(%BeginnersWorkshop{status: "scheduled", date: date}, reading),
    do: Date.compare(reading.today, date) == :gt

  def finalisation_due?(%BeginnersWorkshop{}, _reading), do: false

  @doc """
  When attended people get the Follow-up (story 99): 10:00 Dublin time the
  morning after Attendance Finalisation. Finalisation always belongs to the
  workshop date — Finish opens with check-in on that day, and the automatic
  pass finalises at its end (its first sweep after midnight) — so the
  morning after is the day after the workshop date.
  """
  @spec follow_up_at(BeginnersWorkshop.t() | %{date: Date.t()}) :: DateTime.t()
  def follow_up_at(%{date: date}), do: ClubCalendar.to_utc(Date.add(date, 1), @follow_up_time)

  @doc "Whether the Follow-up is due at `reading`: the workshop is finalised and it is 10:00 the morning after or later."
  @spec follow_up_due?(BeginnersWorkshop.t(), map()) :: boolean()
  def follow_up_due?(%BeginnersWorkshop{status: "finalised"} = workshop, reading),
    do: DateTime.compare(reading.now, follow_up_at(workshop)) != :lt

  def follow_up_due?(%BeginnersWorkshop{}, _reading), do: false

  defp window_open?(%{latest_window_end: nil}, _reading), do: false

  defp window_open?(%{latest_window_end: window_end}, reading),
    do: DateTime.compare(reading.now, window_end) == :lt

  defp before_first_batch?(_workshop, %{batches_sent: sent}, _reading) when sent > 0, do: false

  defp before_first_batch?(workshop, _facts, reading) do
    case Date.compare(reading.today, workshop.contact_from) do
      :lt -> true
      :eq -> Time.compare(reading.now_time, @batch_time) == :lt
      :gt -> false
    end
  end
end
