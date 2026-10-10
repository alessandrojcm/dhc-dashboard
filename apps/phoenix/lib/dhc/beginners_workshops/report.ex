defmodule Dhc.BeginnersWorkshops.Report do
  @moduledoc """
  The Dashboard tab's Beginners' Workshop report (ALE-397, ALE-373): queue
  health, planning figures and per-workshop outcomes. A lock-free,
  actor-free read model — the `WorkshopList` / `Invitable` shape: live
  queries, no stored aggregates, nothing that calls `execute/3`. The
  route's `beginners.workshops.manage` gate is its whole authorization.

  Waitlist standing is read through `Dhc.Waitlist` (`queue_report/1`,
  `standings/1`). Every figure is an Intake count, so a person contacted
  twice counts twice up to Paid.

  ## Rules

    * **Outcomes** list past workshops (finalised or cancelled), newest
      first. Paid means the Intake was ever paid (`paid_at`), whatever
      happened next.
    * **Rates** are out of the Intakes that could take the step: exits
      before paying out of contacted; exits after paying out of paid;
      attendance out of the paid people still seated at Attendance
      Finalisation (attended + no-show, including a no-show later corrected
      to deferred); the Conversion Rate is joined ÷ attended.
    * **Cancelled workshops** are listed with their counts but carry no
      rates and are left out of every 12-month figure: a club-caused
      deferral is not a person's choice.
    * **Anonymised Intakes** (ALE-396) count everywhere: their queue date
      is kept, and an attended one's `invitation_outcome` stands in for the
      deleted standing. The report has no age or gender figures (those are
      `Dhc.Waitlist.analytics/0`'s, over waiting people only).
    * **Planning** figures cover finalised workshops whose Dublin date is in
      the last 12 months: time to a seat (Batch Intakes that attended,
      queue date → workshop date), average attendees, workshops needed to
      clear the queue, and the 12-month Conversion Rate.
    * "Time to first contact" is deliberately absent: anonymisation breaks
      the link between a person's Intakes.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeEvent,
    Invitable,
    WorkshopPolicy
  }

  alias Dhc.{ClubCalendar, Repo, Waitlist}

  @type rate :: float() | nil

  @type group :: %{
          kind: :batch | :fast_track,
          number: pos_integer() | nil,
          window_ends_at: DateTime.t() | nil,
          contacted: non_neg_integer(),
          paid_in_window: non_neg_integer(),
          paid_later: non_neg_integer(),
          declined: non_neg_integer(),
          unpaid_at_cutoff: non_neg_integer()
        }

  @type outcome :: %{
          workshop_id: binary(),
          date: Date.t(),
          venue: String.t(),
          status: String.t(),
          batches_sent: non_neg_integer(),
          contacted: %{
            total: non_neg_integer(),
            batch: non_neg_integer(),
            fast_track: non_neg_integer()
          },
          exits_before_paying: map(),
          paid: %{total: non_neg_integer(), carried_fee: non_neg_integer()},
          exits_after_paying: map(),
          attendance: map(),
          after_attending: map(),
          conversion_rate: rate(),
          groups: [group()]
        }

  @type t :: %{
          queue: map(),
          twelve_months: map(),
          outcomes: [outcome()]
        }

  @exits_before ~w(declined lapsed returned withdrawn)
  @exits_after ~w(deferred cancelled_refunded withdrawn)

  @doc "The report at the clock's current reading."
  @spec load(Clock.t()) :: t()
  def load(%Clock{} = clock) do
    reading = Clock.read(clock)
    since = Date.shift(reading.today, year: -1)

    workshops =
      Repo.all(
        from(w in BeginnersWorkshop,
          where: w.status in ["finalised", "cancelled"],
          order_by: [desc: w.date, desc: w.start_time, desc: w.id]
        )
      )

    ids = Enum.map(workshops, & &1.id)
    intakes = intakes(ids)
    batches = batches(ids)
    events = events(Enum.map(intakes, & &1.id))

    standings =
      intakes
      |> Enum.filter(&(&1.state == "attended" and &1.waitlist_id))
      |> Enum.map(& &1.waitlist_id)
      |> Waitlist.standings()

    by_workshop = Enum.group_by(intakes, & &1.workshop_id)

    outcomes =
      for workshop <- workshops do
        rows = Map.get(by_workshop, workshop.id, [])
        outcome(workshop, rows, Map.get(batches, workshop.id, []), events, standings)
      end

    recent =
      Enum.filter(
        Enum.zip(workshops, outcomes),
        fn {workshop, _outcome} ->
          workshop.status == "finalised" and Date.compare(workshop.date, since) == :gt and
            Date.compare(workshop.date, reading.today) != :gt
        end
      )

    queue = Waitlist.queue_report(reading.now)
    twelve_months = twelve_months(recent, by_workshop)

    %{
      queue: queue_figures(queue, reading, twelve_months),
      twelve_months: Map.delete(twelve_months, :days_to_seat),
      outcomes: outcomes
    }
  end

  # ── queries ──────────────────────────────────────────────────────

  defp intakes([]), do: []

  defp intakes(workshop_ids) do
    Repo.all(
      from(i in Intake,
        where: i.workshop_id in ^workshop_ids,
        select:
          map(i, [
            :id,
            :workshop_id,
            :waitlist_id,
            :state,
            :origin,
            :batch_id,
            :queue_date,
            :contacted_at,
            :paid_at,
            :paid_via,
            :invitation_outcome
          ])
      )
    )
  end

  defp batches([]), do: %{}

  defp batches(workshop_ids) do
    from(b in Batch,
      where: b.workshop_id in ^workshop_ids,
      order_by: [asc: b.number],
      select: map(b, [:id, :workshop_id, :number, :window_ends_at])
    )
    |> Repo.all()
    |> Enum.group_by(& &1.workshop_id)
  end

  # The history rows that change what a state means: a `returned` Intake
  # of a cancelled workshop was returned by the cancellation (not by the
  # cutoff), and a `deferred` one corrected from no-show was seated at
  # finalisation (not an exit after paying).
  defp events([]), do: %{cancelled: MapSet.new(), corrected_deferral: MapSet.new()}

  defp events(intake_ids) do
    rows =
      Repo.all(
        from(e in IntakeEvent,
          where:
            e.intake_id in ^intake_ids and
              (e.command == "cancel_workshop" or
                 (e.command == "correct_attendance" and e.correction == "deferred")),
          select: {e.intake_id, e.command}
        )
      )

    %{
      cancelled: for({id, "cancel_workshop"} <- rows, into: MapSet.new(), do: id),
      corrected_deferral: for({id, "correct_attendance"} <- rows, into: MapSet.new(), do: id)
    }
  end

  defp carried_fees do
    Repo.one(
      from(f in CarriedFee,
        where: f.status == "held",
        select: %{
          count: count(f.id),
          total_paid_cents: coalesce(sum(f.amount_cents), 0),
          unlinked: filter(count(f.id), is_nil(f.amount_cents))
        }
      )
    )
  end

  # ── one workshop ─────────────────────────────────────────────────

  defp outcome(workshop, rows, batches, events, standings) do
    cancelled? = workshop.status == "cancelled"
    paid = Enum.filter(rows, & &1.paid_at)
    unpaid = Enum.reject(rows, & &1.paid_at)
    corrected? = &MapSet.member?(events.corrected_deferral, &1.id)

    before = counts(unpaid, @exits_before)
    after_paying = counts(Enum.reject(paid, corrected?), @exits_after)
    attended = count_state(rows, "attended")
    no_show = count_state(rows, "no_show") + Enum.count(rows, corrected?)
    after_attending = after_attending(rows, standings)

    %{
      workshop_id: workshop.id,
      date: workshop.date,
      venue: workshop.venue,
      status: workshop.status,
      batches_sent: length(batches),
      contacted: %{
        total: length(rows),
        batch: Enum.count(rows, &(&1.origin == "batch")),
        fast_track: Enum.count(rows, &(&1.origin == "fast_track"))
      },
      exits_before_paying: Map.put(before, :rate, rate(cancelled?, before.total, length(rows))),
      paid: %{
        total: length(paid),
        carried_fee: Enum.count(paid, &(&1.paid_via == "carried_fee"))
      },
      exits_after_paying:
        Map.put(after_paying, :rate, rate(cancelled?, after_paying.total, length(paid))),
      attendance: %{
        seated: attended + no_show,
        attended: attended,
        no_show: no_show,
        rate: rate(cancelled?, attended, attended + no_show)
      },
      after_attending: after_attending,
      conversion_rate: rate(cancelled?, after_attending.joined, attended),
      groups: groups(workshop, rows, batches, events)
    }
  end

  defp counts(rows, states) do
    counts = Map.new(states, &{String.to_atom(&1), count_state(rows, &1)})
    Map.put(counts, :total, counts |> Map.values() |> Enum.sum())
  end

  defp count_state(rows, state), do: Enum.count(rows, &(&1.state == state))

  # What became of the attendees: the standing of a person still on the
  # Waitlist, or what an anonymised Intake recorded before its person was
  # deleted.
  defp after_attending(rows, standings) do
    outcomes =
      for %{state: "attended"} = row <- rows do
        case row.waitlist_id do
          nil -> row.invitation_outcome
          id -> Map.get(standings, id)
        end
      end

    %{
      invitable: Enum.count(outcomes, &(&1 == "attended")),
      invited_not_joined: Enum.count(outcomes, &(&1 == "invited")),
      joined: Enum.count(outcomes, &(&1 == "joined"))
    }
  end

  # Each Batch, then the fast-tracks as one group (present only if any).
  defp groups(workshop, rows, batches, events) do
    by_batch = Enum.group_by(rows, & &1.batch_id)

    batch_groups =
      for batch <- batches do
        group(:batch, batch.number, batch.window_ends_at, Map.get(by_batch, batch.id, []), events)
      end

    fast_tracks = Enum.filter(rows, &(&1.origin == "fast_track"))

    fast_track_group =
      if fast_tracks == [],
        do: [],
        else: [group(:fast_track, nil, nil, fast_tracks, events, workshop)]

    batch_groups ++ fast_track_group
  end

  defp group(kind, number, window_ends_at, rows, events, workshop \\ nil) do
    window_end = fn row -> window_ends_at || fast_track_window_end(workshop, row) end
    paid = Enum.filter(rows, & &1.paid_at)
    in_window? = &(DateTime.compare(&1.paid_at, window_end.(&1)) != :gt)

    %{
      kind: kind,
      number: number,
      window_ends_at: window_ends_at,
      contacted: length(rows),
      paid_in_window: Enum.count(paid, in_window?),
      paid_later: Enum.count(paid, &(not in_window?.(&1))),
      declined: count_state(rows, "declined"),
      unpaid_at_cutoff:
        Enum.count(
          rows,
          &(&1.state in ~w(lapsed returned) and not MapSet.member?(events.cancelled, &1.id))
        )
    }
  end

  # A fast-track's window is the Payment Cutoff, or the start for a Carried
  # Fee holder placed after the cutoff (`fast_track_window_end/2` in the
  # boundary).
  defp fast_track_window_end(workshop, row) do
    if DateTime.compare(row.contacted_at, workshop.payment_cutoff) == :lt,
      do: workshop.payment_cutoff,
      else: WorkshopPolicy.starts_at(workshop)
  end

  # ── planning ─────────────────────────────────────────────────────

  defp twelve_months(recent, by_workshop) do
    workshops = length(recent)
    attended = recent |> Enum.map(fn {_w, o} -> o.attendance.attended end) |> Enum.sum()
    joined = recent |> Enum.map(fn {_w, o} -> o.after_attending.joined end) |> Enum.sum()

    days_to_seat =
      for {workshop, _outcome} <- recent,
          %{state: "attended", origin: "batch"} = row <- Map.get(by_workshop, workshop.id, []),
          do: Date.diff(workshop.date, ClubCalendar.on_date(row.queue_date))

    %{
      workshops: workshops,
      attended: attended,
      joined: joined,
      invitable: recent |> Enum.map(fn {_w, o} -> o.after_attending.invitable end) |> Enum.sum(),
      invited_not_joined:
        recent |> Enum.map(fn {_w, o} -> o.after_attending.invited_not_joined end) |> Enum.sum(),
      average_attendees: if(workshops > 0, do: attended / workshops),
      conversion_rate: rate(false, joined, attended),
      days_to_seat: days_to_seat
    }
  end

  defp queue_figures(queue, reading, twelve_months) do
    waits = Enum.map(queue.waiting_since, &Date.diff(reading.today, ClubCalendar.on_date(&1)))
    waiting = length(waits)

    %{
      waiting: waiting,
      median_wait_days: median(waits),
      longest_wait_days: Enum.max(waits, fn -> nil end),
      median_days_to_seat: median(twelve_months.days_to_seat),
      workshops_to_clear: workshops_to_clear(waiting, twelve_months.average_attendees),
      removed_in_retention: queue.removed_in_retention,
      invitable: length(Invitable.list()),
      carried_fees: carried_fees()
    }
  end

  defp workshops_to_clear(_waiting, nil), do: nil
  defp workshops_to_clear(_waiting, average) when average == 0, do: nil
  defp workshops_to_clear(waiting, average), do: ceil(waiting / average)

  @doc false
  @spec median([number()]) :: number() | nil
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1,
      do: Enum.at(sorted, middle),
      else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
  end

  defp rate(true = _cancelled?, _numerator, _denominator), do: nil
  defp rate(_cancelled?, _numerator, 0), do: nil
  defp rate(_cancelled?, numerator, denominator), do: numerator / denominator
end
