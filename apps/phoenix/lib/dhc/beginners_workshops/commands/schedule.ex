defmodule Dhc.BeginnersWorkshops.Commands.Schedule do
  @moduledoc """
  The workshop lifecycle commands of the Beginners' Workshop boundary
  (ALE-405): `schedule_workshop`, `update_workshop`, `reschedule_workshop`,
  `cancel_workshop`, `pause_batches` and `resume_batches`, all
  `beginners.workshops.manage`. `Dhc.BeginnersWorkshops.Commands` authorizes
  the actor and routes here; every body runs inside `Commands.Protocol`.

  ## Schedule and update

  `schedule_workshop` creates up to 20 workshops in one transaction (a
  failure names the 0-based workshop: `{:workshop, index, reason}`), each
  with optional Staff. `update_workshop` edits capacity, fee, Payment
  Cutoff, contact-from date and window length before Attendance
  Finalisation: lowering capacity below the seats taken is
  `:capacity_below_taken`, a fee once people were contacted `:fee_locked`,
  a contact-from date once Batch 1 went out `:contact_from_locked`, and an
  earlier cutoff ends an open Batch window with it. The attributes are the
  `Commands.command/0` typedoc's.

  `pause_batches` / `resume_batches` stop and restart new Batches only.

  ## Reschedule (ALE-394)

  `reschedule_workshop` moves a scheduled workshop's date, start time
  and/or venue at any time before Attendance Finalisation; it is refused
  only with `:after_finalisation` or `:already_cancelled` (and a pending
  Batch never blocks it). Under the Beginners' Workshop lock, then the open
  Intakes:

    * the Payment Cutoff keeps its (Dublin civil) offset before the start
      unless a new date or time is supplied, and every open Batch window
      ending after the new cutoff is brought forward to it;
    * while Batch 1 has not gone out, the contact-from date keeps its offset
      before the workshop date unless one is supplied (`update_workshop`'s
      rules judge a supplied one); a kept date that would fall after the new
      cutoff date is brought forward to Dublin today, so Batch 1 goes out at
      the next 10:00;
    * "Workshop rescheduled" is queued to every open Intake (log occasion
      `rescheduled:<n>`); seats, holds and windows' people are untouched;
    * the workshop's `reschedule_count` names the reschedule: Pre-workshop
      info is owed once per schedule (occasion
      `IntakeEmails.Occasion.pre_workshop/1`), so anyone who had it gets it
      again at the new cutoff through the same Payment Cutoff pass;
    * every Staff member (the actor included) gets a keyed Notification
      (`beginners-workshop:<id>:rescheduled:<n>`), signalled after commit.

  Nothing is scheduled per workshop, so no job needs rewriting.

  ## Cancel (ALE-395)

  `cancel_workshop` (`beginners.workshops.manage`, optional `reason` ≤ 500)
  cancels a scheduled workshop at any time before Attendance Finalisation
  (`:after_finalisation` / `:already_cancelled` otherwise). Under the
  Beginners' Workshop lock, then the open Intakes' Waitlist entries, the
  open Intakes, those people's live Carried Fees and the workshop's live
  Seat Holds and paying payments:

    * every `paid` Intake is deferred exactly as `defer` does it (a
      Stripe-paid one creates a `held` Carried Fee, a Carried-Fee-paid
      one's fee goes back to `held`), its door check-in is discarded, and
      "Workshop cancelled – paid" is queued instead of "Deferred";
    * every `contacted` Intake becomes `returned` (the person `waiting`
      with their original priority; a holder keeps their `held` fee), its
      live Seat Hold `releasing`, and "Workshop cancelled – unpaid" is
      queued — both with log occasion `cancelled`;
    * each Intake gets a `cancel_workshop` history row carrying the reason;
    * every Staff member (the actor included) gets the keyed Notification
      `beginners-workshop:<id>:cancelled`, signalled after commit.

  Every time-driven pass, the Intake page's commands and the door judge
  `status = scheduled`, so nothing happens to the workshop afterwards. A
  completion that arrives for a `releasing` hold is refunded in full by
  `complete_payment`'s `paid_after_close`. People move to another workshop
  by being fast-tracked there as Carried Fee holders, who then confirm.

  ## Cross-family calls

  Staff is `Commands.Staff`'s: `schedule_workshop` reads and applies
  optional Staff through `Staff.staff_input/1` and `Staff.apply_staff/4`,
  and the reschedule and cancel Notifications go through
  `Staff.notify_each_staff/3` and `Staff.when_where/1`. A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      required: 1,
      signal_after_commit: 1,
      transact: 1,
      transition: 3,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1, fetch_attr: 2]

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules,
    only: [facts_for: 1, still_scheduled: 1]

  import Dhc.BeginnersWorkshops.Commands.IntakeHistory,
    only: [bounded_note: 1, record_intake_event: 5]

  import Dhc.BeginnersWorkshops.Commands.IntakeNotices,
    only: [emailed_each: 2]

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeEmails,
    IntakePayment,
    IntakeRefund,
    WorkshopPolicy,
    WorkshopProjection
  }

  alias Dhc.BeginnersWorkshops.Commands

  alias Dhc.BeginnersWorkshops.Commands.{
    Settlement,
    Staff
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.{Occasion}
  alias Dhc.ClubCalendar
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  # One request plans a season, not a year of weekly sessions.
  @max_scheduled_at_once 20

  @schedule_types %{
    venue: :string,
    date: :date,
    start_time: :time,
    capacity: :integer,
    fee_cents: :integer,
    payment_cutoff_date: :date,
    payment_cutoff_time: :time,
    contact_from: :date,
    payment_window_days: :integer
  }

  @update_fields ~w(capacity fee_cents payment_cutoff_date payment_cutoff_time contact_from payment_window_days)a

  @reschedule_fields ~w(venue date start_time payment_cutoff_date payment_cutoff_time contact_from)a

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run({:staff, principal_id}, {:schedule_workshop, list}, clock) when is_list(list) do
    cond do
      list == [] ->
        {:error, :no_workshops}

      length(list) > @max_scheduled_at_once ->
        {:error, :too_many_workshops}

      true ->
        # A new workshop has no row to lock yet; the clock is still read
        # inside the transaction that writes it.
        fn -> schedule_all(list, principal_id, Clock.read(clock)) end
        |> transact()
        |> signal_after_commit()
    end
  end

  def run({:staff, _principal_id}, {:update_workshop, workshop_id, attrs}, clock)
      when is_map(attrs) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id))},
          &update_locked(&1, attrs, clock)
        )
      end)
    end
  end

  def run({:staff, _principal_id}, {:reschedule_workshop, workshop_id, attrs}, clock)
      when is_map(attrs) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            intake: &open_intakes/1
          },
          &reschedule_locked(&1, attrs, clock)
        )
      end
      |> transact()
      |> signal_after_commit()
    end
  end

  def run({:staff, principal_id}, {:cancel_workshop, workshop_id, attrs}, clock)
      when is_map(attrs),
      do: cancel_workshop(principal_id, workshop_id, attrs, clock)

  def run({:staff, principal_id}, {:pause_batches, workshop_id}, clock),
    do: set_batches_paused(workshop_id, principal_id, true, clock)

  def run({:staff, principal_id}, {:resume_batches, workshop_id}, clock),
    do: set_batches_paused(workshop_id, principal_id, false, clock)

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── schedule_workshop ───────────────────────────────────────────

  defp schedule_all(list, principal_id, reading) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], []}}, fn {attrs, index}, {:ok, {views, created}} ->
      case schedule_one(attrs, principal_id, reading) do
        {:ok, {view, notifications}} -> {:cont, {:ok, {[view | views], created ++ notifications}}}
        {:error, reason} -> {:halt, {:error, {:workshop, index, reason}}}
      end
    end)
    |> case do
      {:ok, {views, created}} -> {:ok, {Enum.reverse(views), created}}
      error -> error
    end
  end

  defp schedule_one(attrs, principal_id, reading) when is_map(attrs) do
    input =
      {%{}, @schedule_types}
      |> Ecto.Changeset.cast(attrs, Map.keys(@schedule_types))
      |> Ecto.Changeset.validate_required([:venue, :date, :start_time, :capacity, :fee_cents])

    with {:ok, input} <- Ecto.Changeset.apply_action(input, :insert),
         {:ok, staff} <- Staff.staff_input(attrs),
         starts_at = WorkshopPolicy.starts_at(input),
         :ok <- in_future(starts_at, reading),
         cutoff = resolve_cutoff(input, input),
         :ok <- cutoff_before_start(cutoff, starts_at),
         contact_from = Map.get(input, :contact_from) || reading.today,
         :ok <- contact_from_on_or_before(contact_from, cutoff),
         {:ok, workshop} <-
           input
           |> Map.take([:venue, :date, :start_time, :capacity, :fee_cents])
           |> Map.merge(%{
             payment_cutoff: cutoff,
             contact_from: contact_from,
             payment_window_days:
               Map.get(input, :payment_window_days) ||
                 WorkshopPolicy.default_payment_window_days(),
             scheduled_by_principal_id: principal_id
           })
           |> BeginnersWorkshop.schedule_changeset()
           |> persist(),
         {:ok, created} <- Staff.apply_staff(workshop, [], staff, principal_id) do
      {:ok, {WorkshopProjection.view(workshop, facts_for(workshop), reading), created}}
    end
  end

  defp schedule_one(_attrs, _principal_id, _reading),
    do: {:error, Ecto.Changeset.change({%{}, @schedule_types})}

  # ── update_workshop ─────────────────────────────────────────────

  defp update_locked(%{workshop: workshop}, attrs, clock),
    do: update_settings(workshop, facts_for(workshop), attrs, Clock.read(clock))

  defp update_settings(%BeginnersWorkshop{status: "finalised"}, _facts, _attrs, _reading),
    do: {:error, :after_finalisation}

  defp update_settings(%BeginnersWorkshop{status: "cancelled"}, _facts, _attrs, _reading),
    do: {:error, :already_cancelled}

  defp update_settings(%BeginnersWorkshop{} = workshop, facts, attrs, reading) do
    current = %{
      capacity: workshop.capacity,
      fee_cents: workshop.fee_cents,
      payment_cutoff_date: ClubCalendar.on_date(workshop.payment_cutoff),
      payment_cutoff_time:
        workshop.payment_cutoff |> ClubCalendar.time_on() |> Time.truncate(:second),
      contact_from: workshop.contact_from,
      payment_window_days: workshop.payment_window_days
    }

    input =
      {current, Map.take(@schedule_types, @update_fields)}
      |> Ecto.Changeset.cast(attrs, @update_fields)

    with {:ok, next} <- Ecto.Changeset.apply_action(input, :update),
         :ok <- fee_change_allowed(input, facts),
         :ok <- capacity_change_allowed(input, next.capacity, facts),
         :ok <- contact_from_change_allowed(input, facts),
         cutoff = resolve_cutoff(next, workshop),
         :ok <- cutoff_before_start(cutoff, WorkshopPolicy.starts_at(workshop)),
         :ok <- contact_from_still_valid(next.contact_from, cutoff, facts),
         # Capacity may rise at any time before finalisation; lowering it
         # below the seats taken (paid + live holds) is refused. A new window length applies to Batches sent after it: a sent
         # Batch keeps its stored window end.
         {:ok, workshop} <-
           workshop
           |> BeginnersWorkshop.settings_changeset(%{
             capacity: next.capacity,
             fee_cents: next.fee_cents,
             payment_cutoff: cutoff,
             contact_from: next.contact_from,
             payment_window_days: next.payment_window_days
           })
           |> persist(),
         # An earlier cutoff ends an open Batch window with it, as a
         # reschedule's does.
         :ok <- clamp_open_windows(workshop, reading) do
      {:ok, WorkshopProjection.view(workshop, facts_for(workshop), reading)}
    end
  end

  # Seats taken are judged under the workshop lock every hold takes.
  defp capacity_change_allowed(input, capacity, facts) do
    if Ecto.Changeset.changed?(input, :capacity) and
         not WorkshopPolicy.capacity_allowed?(capacity, facts),
       do: {:error, :capacity_below_taken},
       else: :ok
  end

  # People contacted at one price are never charged another.
  defp fee_change_allowed(input, facts) do
    if Ecto.Changeset.changed?(input, :fee_cents) and not WorkshopPolicy.fee_editable?(facts),
      do: {:error, :fee_locked},
      else: :ok
  end

  defp contact_from_change_allowed(input, facts) do
    if Ecto.Changeset.changed?(input, :contact_from) and
         not WorkshopPolicy.contact_from_editable?(facts),
       do: {:error, :contact_from_locked},
       else: :ok
  end

  # Once Batch 1 has gone out the contact-from date has done its job, so a
  # later cutoff edit is not judged against it.
  defp contact_from_still_valid(contact_from, cutoff, facts) do
    if WorkshopPolicy.contact_from_editable?(facts),
      do: contact_from_on_or_before(contact_from, cutoff),
      else: :ok
  end

  # ── reschedule_workshop ─────────────────────────────────────────

  # Every open Intake of the workshop: each is told about the move.
  defp open_intakes(%{workshop: workshop}) do
    open = Intake.open_states()
    {:all, from(i in Intake, where: i.workshop_id == ^workshop.id and i.state in ^open)}
  end

  defp reschedule_locked(%{workshop: workshop, intake: intakes}, attrs, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         facts = facts_for(workshop),
         {:ok, input, next} <- reschedule_input(workshop, attrs),
         :ok <- moved_start_in_future(input, next, reading),
         cutoff = rescheduled_cutoff(workshop, next),
         :ok <- cutoff_before_start(cutoff, WorkshopPolicy.starts_at(next)),
         {:ok, contact_from} <-
           rescheduled_contact_from(workshop, input, next, cutoff, facts, reading),
         {:ok, workshop} <-
           workshop
           |> BeginnersWorkshop.reschedule_changeset(%{
             venue: next.venue,
             date: next.date,
             start_time: next.start_time,
             payment_cutoff: cutoff,
             contact_from: contact_from
           })
           |> persist(),
         :ok <- clamp_open_windows(workshop, reading),
         :ok <-
           emailed_each(
             intakes,
             &IntakeEmails.deliver(
               {:intake, &1, workshop},
               "rescheduled",
               Occasion.rescheduled(workshop.reschedule_count),
               reading
             )
           ),
         {:ok, created} <- notify_rescheduled(workshop) do
      {:ok, {WorkshopProjection.view(workshop, facts_for(workshop), reading), created}}
    end
  end

  # The new values over the current ones; at least one of the date, start
  # time and venue must change (otherwise there is nothing to tell anyone).
  defp reschedule_input(workshop, attrs) do
    current = %{
      venue: workshop.venue,
      date: workshop.date,
      start_time: workshop.start_time,
      payment_cutoff_date: nil,
      payment_cutoff_time: nil,
      contact_from: workshop.contact_from
    }

    input =
      {current, Map.take(@schedule_types, @reschedule_fields)}
      |> Ecto.Changeset.cast(attrs, @reschedule_fields)
      |> Ecto.Changeset.update_change(:venue, &String.trim/1)
      |> Ecto.Changeset.validate_required([:venue, :date, :start_time, :contact_from])
      |> Ecto.Changeset.validate_length(:venue, min: 1, max: BeginnersWorkshop.venue_max())
      |> require_a_move(workshop)

    with {:ok, next} <- Ecto.Changeset.apply_action(input, :update), do: {:ok, input, next}
  end

  defp require_a_move(input, workshop) do
    moved? =
      Enum.any?([:date, :start_time, :venue], fn field ->
        Ecto.Changeset.get_field(input, field) != Map.fetch!(workshop, field)
      end)

    if moved?,
      do: input,
      else: Ecto.Changeset.add_error(input, :date, "change the date, start time or venue")
  end

  # Only a new start is judged against the clock: a venue correction on the
  # day (or after it, before finalisation) still goes through.
  defp moved_start_in_future(input, next, reading) do
    if Ecto.Changeset.changed?(input, :date) or Ecto.Changeset.changed?(input, :start_time),
      do: in_future(WorkshopPolicy.starts_at(next), reading),
      else: :ok
  end

  # The cutoff keeps its Dublin civil offset before the start; a supplied
  # date or time replaces that half of the kept cutoff.
  defp rescheduled_cutoff(workshop, next) do
    kept = WorkshopPolicy.kept_offset_cutoff(workshop, next)

    ClubCalendar.to_utc(
      next.payment_cutoff_date || ClubCalendar.on_date(kept),
      next.payment_cutoff_time || kept |> ClubCalendar.time_on() |> Time.truncate(:second)
    )
  end

  # `update_workshop`'s rules judge a supplied contact-from date; a kept one
  # follows the workshop date, or comes forward to today when it would land
  # after the new cutoff date. Once Batch 1 has gone out it no longer
  # matters and stays as it was.
  defp rescheduled_contact_from(workshop, input, next, cutoff, facts, reading) do
    cond do
      not WorkshopPolicy.contact_from_editable?(facts) ->
        with :ok <- contact_from_change_allowed(input, facts), do: {:ok, workshop.contact_from}

      Ecto.Changeset.changed?(input, :contact_from) ->
        with :ok <- contact_from_still_valid(next.contact_from, cutoff, facts),
             do: {:ok, next.contact_from}

      true ->
        {:ok, WorkshopPolicy.kept_contact_from(workshop, next.date, cutoff, reading)}
    end
  end

  # Every open Batch window ending after the (new) Payment Cutoff ends at it:
  # the one clamp of `update_workshop` and `reschedule_workshop`. Written
  # under the workshop lock, which every Batch writer holds.
  defp clamp_open_windows(workshop, reading) do
    # A window can't end before it was sent: one past the new cutoff closes now.
    clamp_to = Enum.max([workshop.payment_cutoff, reading.now], DateTime)

    from(b in Batch,
      where:
        b.workshop_id == ^workshop.id and b.window_ends_at > ^reading.now and
          b.window_ends_at > ^clamp_to
    )
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case batch |> Batch.clamp_window_changeset(clamp_to) |> persist() do
        {:ok, _batch} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Assigned Staff stay assigned; each one (the actor included) hears about
  # the move, keyed by this reschedule so the next one notifies again.
  defp notify_rescheduled(workshop) do
    key = "beginners-workshop:#{workshop.id}:rescheduled:#{workshop.reschedule_count}"

    Staff.notify_each_staff(
      workshop,
      key,
      "The Beginners' Workshop you're on has moved to #{Staff.when_where(workshop)}."
    )
  end

  # ── cancel_workshop (ALE-395) ───────────────────────────────────

  defp cancel_workshop(principal_id, workshop_id, attrs, clock) do
    with {:ok, reason} <- cancel_reason(attrs),
         {:ok, workshop_id} <- cast_id(workshop_id) do
      fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: &cancel_entries/1,
            intake: &cancel_intakes/1,
            carried_fee: &cancel_fees/1,
            payment: &cancel_payments/1
          },
          &cancel_locked(&1, principal_id, reason, clock)
        )
      end
      |> transact()
      |> signal_after_commit()
    end
  end

  # Optional, at most a history note's length; blank is no reason.
  defp cancel_reason(attrs) do
    case fetch_attr(attrs, :reason) do
      nil ->
        {:ok, nil}

      reason when is_binary(reason) ->
        case reason |> String.trim() |> bounded_note() do
          {:ok, reason} -> {:ok, reason}
          {:error, :invalid_note} -> {:error, :invalid_reason}
        end

      _other ->
        {:error, :invalid_reason}
    end
  end

  # Every Intake is created and closed under the workshop lock, so its open
  # Intakes cannot change once it is held. Nothing more is locked when the
  # workshop is no longer scheduled.
  defp cancel_open_intakes(workshop),
    do:
      from(i in Intake,
        where: i.workshop_id == ^workshop.id and i.state in ^Intake.open_states()
      )

  defp cancel_entries(%{workshop: %BeginnersWorkshop{status: "scheduled"} = workshop}) do
    people = workshop |> cancel_open_intakes() |> select([i], i.waitlist_id)
    {:all, from(e in WaitlistEntry, where: e.id in subquery(people))}
  end

  defp cancel_entries(_locked), do: nil

  defp cancel_intakes(%{workshop: workshop, waitlist_entry: entries}) when is_list(entries),
    do: {:all, cancel_open_intakes(workshop)}

  defp cancel_intakes(_locked), do: nil

  # The live Carried Fees of the people with an open Intake: a
  # Carried-Fee-paid Intake's fee goes back to `held`, and a contacted
  # holder keeps theirs.
  defp cancel_fees(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    people = workshop |> cancel_open_intakes() |> select([i], i.waitlist_id)

    {:all,
     from(f in CarriedFee,
       where: f.waitlist_id in subquery(people) and f.status in ^CarriedFee.live_statuses()
     )}
  end

  defp cancel_fees(_locked), do: nil

  # The live Seat Holds (released) and the payments that paid the paid
  # Intakes (`paying_payment/1`'s rule: a deferral's Carried Fee points at
  # one).
  defp cancel_payments(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    paid = from(i in Intake, where: i.workshop_id == ^workshop.id and i.state == "paid")
    automatic = IntakeRefund.automatic_reasons()

    {:all,
     from(p in IntakePayment,
       as: :payment,
       where: p.workshop_id == ^workshop.id,
       where:
         p.status == "open" or
           (p.status == "paid" and p.intake_id in subquery(select(paid, [i], i.id)) and
              not exists(
                from(r in IntakeRefund,
                  where: r.payment_id == parent_as(:payment).id and r.reason in ^automatic
                )
              ))
     )}
  end

  defp cancel_payments(_locked), do: nil

  defp cancel_locked(%{workshop: workshop} = locked, actor_id, reason, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         context = %{actor: actor_id, note: reason, options: %{}},
         {:ok, tally} <- cancel_all(locked, context, reading),
         {:ok, workshop} <-
           transition(
             :workshop,
             workshop,
             BeginnersWorkshop.cancel_changeset(workshop, actor_id, reason, reading.now)
           ),
         {:ok, created} <- notify_cancelled(workshop) do
      view = WorkshopProjection.view(workshop, facts_for(workshop), reading)
      {:ok, {Map.merge(tally, %{workshop: view}), created}}
    end
  end

  defp cancel_all(locked, context, reading) do
    entries = Map.new(locked.waitlist_entry, &{&1.id, &1})
    fees = Map.new(locked.carried_fee, &{&1.waitlist_id, &1})
    payments = Enum.group_by(locked.payment, & &1.intake_id)

    Enum.reduce_while(
      locked.intake,
      {:ok, %{deferred: 0, returned: 0, released: 0}},
      fn intake, {:ok, tally} ->
        one = %{
          workshop: locked.workshop,
          waitlist_entry: Map.get(entries, intake.waitlist_id),
          intake: intake,
          carried_fee: Map.get(fees, intake.waitlist_id),
          payments: Map.get(payments, intake.id, [])
        }

        case cancel_intake(one, context, reading) do
          {:ok, counted} -> {:cont, {:ok, Map.merge(tally, counted, fn _k, a, b -> a + b end)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  # A paid person is deferred (story 129) and their door check-in
  # discarded; an unpaid one is returned. What that does to the person is
  # the `cancel_workshop` rows of `Commands.Settlement`; each Intake also
  # gets a `cancel_workshop` history row.
  defp cancel_intake(%{intake: %Intake{state: "paid"} = intake} = one, context, reading) do
    ending = if intake.waitlist_id, do: :paid, else: :paid_anonymised

    payment =
      one.payments
      |> Enum.filter(&(&1.status == "paid"))
      |> Enum.min_by(&{DateTime.to_unix(&1.paid_at, :microsecond), &1.id}, fn -> nil end)

    with {:ok, intake} <- discard_check_in(intake),
         {:ok, %{intake: intake}} <-
           Settlement.run(
             {:cancel_workshop, ending},
             %{one | intake: intake} |> Map.put(:payment, payment),
             reading
           ),
         {:ok, _event} <-
           record_intake_event(intake, :cancel_workshop, Ecto.UUID.generate(), context, reading),
         do: {:ok, %{deferred: 1}}
  end

  defp cancel_intake(%{intake: %Intake{state: "contacted"}} = one, context, reading) do
    holds = Enum.filter(one.payments, &(&1.status == "open"))

    with {:ok, %{intake: intake}} <-
           Settlement.run({:cancel_workshop, :contacted}, Map.put(one, :holds, holds), reading),
         {:ok, _event} <-
           record_intake_event(intake, :cancel_workshop, Ecto.UUID.generate(), context, reading),
         do: {:ok, %{returned: 1, released: length(holds)}}
  end

  defp discard_check_in(%Intake{checked_in_at: nil} = intake), do: {:ok, intake}

  defp discard_check_in(%Intake{} = intake),
    do: intake |> Intake.undo_check_in_changeset() |> persist()

  # Assigned Staff stay on the (read-only) record; each one (the actor
  # included) hears that it is off, once.
  defp notify_cancelled(workshop) do
    Staff.notify_each_staff(
      workshop,
      "beginners-workshop:#{workshop.id}:cancelled",
      "The Beginners' Workshop on #{Staff.when_where(workshop)} has been cancelled."
    )
  end

  # ── pause_batches / resume_batches ──────────────────────────────

  # Idempotent: pausing a paused workshop (or resuming a running one)
  # changes nothing and records nothing again.
  defp set_batches_paused(workshop_id, principal_id, paused?, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id))},
          &pause_locked(&1, principal_id, paused?, clock)
        )
      end)
    end
  end

  defp pause_locked(%{workshop: workshop}, principal_id, paused?, clock) do
    reading = Clock.read(clock)

    with :ok <- still_scheduled(workshop),
         {:ok, workshop} <- toggle_pause(workshop, principal_id, paused?, reading) do
      {:ok, WorkshopProjection.view(workshop, facts_for(workshop), reading)}
    end
  end

  defp toggle_pause(%BeginnersWorkshop{batches_paused: paused?} = workshop, _id, paused?, _r),
    do: {:ok, workshop}

  defp toggle_pause(workshop, principal_id, true, reading),
    do: workshop |> BeginnersWorkshop.pause_changeset(principal_id, reading.now) |> persist()

  defp toggle_pause(workshop, principal_id, false, reading),
    do: workshop |> BeginnersWorkshop.resume_changeset(principal_id, reading.now) |> persist()

  # ── Shared rules ────────────────────────────────────────────────

  defp resolve_cutoff(input, %{date: date, start_time: start_time}) do
    ClubCalendar.to_utc(
      Map.get(input, :payment_cutoff_date) || WorkshopPolicy.default_cutoff_date(date),
      Map.get(input, :payment_cutoff_time) || start_time
    )
  end

  defp in_future(starts_at, reading) do
    if DateTime.compare(starts_at, reading.now) == :gt, do: :ok, else: {:error, :start_in_past}
  end

  defp cutoff_before_start(cutoff, starts_at) do
    if WorkshopPolicy.cutoff_before_start?(cutoff, starts_at),
      do: :ok,
      else: {:error, :invalid_payment_cutoff}
  end

  defp contact_from_on_or_before(contact_from, cutoff) do
    if WorkshopPolicy.contact_from_valid?(contact_from, cutoff),
      do: :ok,
      else: {:error, :invalid_contact_from}
  end
end
