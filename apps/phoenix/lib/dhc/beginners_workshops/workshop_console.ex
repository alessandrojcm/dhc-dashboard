defmodule Dhc.BeginnersWorkshops.WorkshopConsole do
  @moduledoc """
  The coordinator console read model of one Beginners' Workshop (ALE-380):
  no locks, no actor (the route's capability gate is the whole
  authorization) — the `Dhc.Inventory.OperatorLoanQueue` shape.

  It carries:

    * `workshop` — `WorkshopProjection.view/3`, the same row the list and
      every workshop command return (stage, seats, alerts);
    * `batches` — every Batch sent, oldest first;
    * `pause` — whether automatic Batches are paused, and who paused or
      resumed them last, and when;
    * `next_batch` — the **Next Batch** preview: `WorkshopPolicy.next_batch/3`
      (when it goes out, or that it is paused, full or closed), its size as
      capacity − paid, and the live `BatchProposal` — exactly the people
      `send_due_batch` would contact now — with minors badged and Carried
      Fee holders marked `confirms` (ALE-388);
    * `roster` — Intakes grouped by meaning: before finalisation `seated`
      (paid), `asked` (contacted, not paid yet) and `out`; after it
      (ALE-391) `attended`, `no_show` and `out`. Each Intake with a live
      Seat Hold carries when its hold runs out (ALE-381), each paid Intake
      its door check-in time (ALE-390), and each Intake with a refund
      carries its latest refund's status, method and whether it was
      automatic (ALE-382), and each its person's Waitlist standing
      (`nil` once anonymised) — after finalisation the attended people's
      standing says who is invited or joined (ALE-392). Every Intake
      (ALE-386) also carries its medical flag, link generation, Intake
      Email log (what was queued and when, plus the scheduled email still owed: "Pre-workshop info" to a `paid`
      Intake for the current schedule, the Follow-up to an `attended` one),
      its history (command, actor, time, note) and its `available_commands`
      — `IntakePolicy.available_commands/1`, the very rule the boundary
      applies under the lock — and (ALE-388) `carried_fee`: the status of
      the Carried Fee that paid it, else of the person's live one, or `nil`.
      After finalisation (ALE-393) a correctable Intake offers
      `correct_attendance`, and `attendance_corrections` lists the states it
      may be corrected to (`IntakePolicy.attendance_corrections/1`); a
      correction's history row names its `correction`;
    * `unpaid_after_window` — the Needs attention list of `contacted`
      people whose payment window (their Batch's, or the Payment Cutoff for
      a fast-track) has ended, oldest window first (ALE-386);
    * `unconfirmed_carried_fees` — the Needs attention list of `contacted`
      Carried Fee holders who have not confirmed yet (ALE-388);
    * `failed_refunds` — the Needs attention list of refunds that failed
      and have not been followed up (Retry or Record manual refund), oldest
      first (ALE-382); `carried_fee` marks a Carried Fee's refund, which can
      also be forfeited, and is listed only while the fee is owed back
      (ALE-389);
    * `finalisation` (ALE-391) — `nil` until Attendance Finalisation, then
      when, who pressed Finish (`nil`: automatically at the end of the day)
      and when the Follow-up goes out (`WorkshopPolicy.follow_up_at/1`),
      and (ALE-392) `invitations`: how many attended, and how many of
      them are now `invited` or `joined` — counted from the attended roster
      rows themselves, so the line and the list cannot disagree;
    * `cancel_preview` (ALE-395) — while the workshop is scheduled, what
      Cancel would do now: how many paid Intakes it defers, contacted ones
      it returns and live Seat Holds it releases (from the roster rows
      themselves, so the dialog and the list cannot disagree); `nil`
      otherwise;
    * `cancellation` (ALE-395) — `nil` unless cancelled, then when, by
      whom (by name) and the optional reason;
    * `attention` — `:nobody_waiting` when a Batch is due with free seats
      but nobody eligible is waiting;
    * `fast_track_open` — whether Fast-track is offered now for anyone
      (`WorkshopPolicy.payment_open?/2`, the rule `fast_track` applies), and
      `fast_track_holders_only` — after the cutoff of a scheduled workshop,
      when only Carried Fee holders may still be fast-tracked (ALE-388).

  Because the preview and the pass share `WorkshopPolicy` and
  `BatchProposal`, a stale console can be out of date but never disagree
  with what the boundary would decide.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BatchProposal,
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    DoorView,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakePayment,
    IntakePolicy,
    IntakeRefund,
    WorkshopFacts,
    WorkshopPolicy,
    WorkshopProjection
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  # Every state with a roster group of its own; the rest are `out`.
  @not_out ~w(contacted paid attended no_show)

  @type t :: %{
          workshop: WorkshopProjection.t(),
          batches: [map()],
          pause: map(),
          next_batch: map(),
          roster: %{
            seated: [map()],
            asked: [map()],
            attended: [map()],
            no_show: [map()],
            out: [map()]
          },
          finalisation:
            %{
              at: DateTime.t(),
              by: String.t() | nil,
              follow_up_at: DateTime.t(),
              invitations: %{
                attended: non_neg_integer(),
                invited: non_neg_integer(),
                joined: non_neg_integer()
              }
            }
            | nil,
          cancel_preview:
            %{
              deferred: non_neg_integer(),
              returned: non_neg_integer(),
              released: non_neg_integer()
            }
            | nil,
          cancellation: %{at: DateTime.t(), by: String.t() | nil, reason: String.t() | nil} | nil,
          failed_refunds: [map()],
          unpaid_after_window: [map()],
          unconfirmed_carried_fees: [map()],
          attention: [:nobody_waiting],
          fast_track_open: boolean(),
          fast_track_holders_only: boolean()
        }

  @doc "The console of `workshop_id` at the clock's current reading."
  @spec show(binary(), Clock.t()) :: {:ok, t()} | {:error, :not_found}
  def show(workshop_id, %Clock{} = clock) do
    with {:ok, id} <- Ecto.UUID.cast(workshop_id),
         %BeginnersWorkshop{} = workshop <- Repo.get(BeginnersWorkshop, id) do
      facts = Map.fetch!(WorkshopFacts.load([id]), id)
      reading = Clock.read(clock)
      next_batch = next_batch(workshop, facts, reading)
      roster = roster(workshop)

      {:ok,
       %{
         workshop: WorkshopProjection.view(workshop, facts, reading),
         batches: batches(id),
         pause: pause(workshop),
         next_batch: next_batch,
         roster: roster,
         failed_refunds: failed_refunds(id),
         unpaid_after_window: unpaid_after_window(roster, reading),
         unconfirmed_carried_fees: unconfirmed_carried_fees(roster),
         attention: attention(next_batch),
         finalisation: finalisation(workshop, roster.attended),
         cancel_preview: cancel_preview(workshop, roster),
         cancellation: cancellation(workshop),
         fast_track_open: WorkshopPolicy.payment_open?(workshop, reading),
         fast_track_holders_only:
           workshop.status == "scheduled" and not WorkshopPolicy.payment_open?(workshop, reading)
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  defp batches(workshop_id) do
    from(b in Batch,
      where: b.workshop_id == ^workshop_id,
      order_by: [asc: b.number],
      select: map(b, [:number, :size, :sent_at, :window_ends_at])
    )
    |> Repo.all()
  end

  defp pause(workshop) do
    %{
      paused: workshop.batches_paused,
      paused_at: workshop.batches_paused_at,
      paused_by: name_of(workshop.batches_paused_by_principal_id),
      resumed_at: workshop.batches_resumed_at,
      resumed_by: name_of(workshop.batches_resumed_by_principal_id)
    }
  end

  defp next_batch(workshop, facts, reading) do
    timing = WorkshopPolicy.next_batch(workshop, facts, reading)
    size = WorkshopPolicy.batch_size(workshop, facts)

    people =
      if timing in [:full, :closed],
        do: [],
        else: Enum.map(BatchProposal.people(size), &person(&1, workshop))

    {status, goes_out_at} =
      case timing do
        {:at, at} -> {:scheduled, at}
        other -> {other, nil}
      end

    %{
      status: status,
      goes_out_at: goes_out_at,
      number: facts.batches_sent + 1,
      size: size,
      capacity: workshop.capacity,
      paid: facts.paid,
      people: people
    }
  end

  defp person(row, workshop) do
    %{
      first_name: row.first_name,
      last_name: row.last_name,
      minor: WorkshopPolicy.minor?(row.date_of_birth, workshop.date),
      queue_date: row.queue_date,
      confirms: row.confirms
    }
  end

  defp roster(workshop) do
    refunds = latest_refunds(workshop.id)
    emails = email_logs(workshop.id)
    history = histories(workshop.id)

    rows =
      from(i in Intake,
        left_join: b in Batch,
        on: b.id == i.batch_id,
        left_join: p in UserProfile,
        on: p.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id),
        left_join: h in IntakePayment,
        on: h.intake_id == i.id and h.status == "open",
        # The fee that paid this Intake, else the person's live one.
        left_join: paid_fee in CarriedFee,
        on: paid_fee.id == i.carried_fee_id,
        left_join: live_fee in CarriedFee,
        on:
          live_fee.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id) and
            live_fee.status in ^CarriedFee.live_statuses(),
        left_join: e in WaitlistEntry,
        on: e.id == i.waitlist_id,
        where: i.workshop_id == ^workshop.id,
        order_by: [asc: i.queue_date, asc: i.id],
        select: %{
          id: i.id,
          state: i.state,
          paid_via: i.paid_via,
          origin: i.origin,
          batch_number: b.number,
          queue_date: i.queue_date,
          contacted_at: i.contacted_at,
          window_ends_at: b.window_ends_at,
          hold_expires_at: h.expires_at,
          checked_in_at: i.checked_in_at,
          standing: e.status,
          link_generation: i.link_generation,
          carried_fee: coalesce(paid_fee.status, live_fee.status),
          first_name: p.first_name,
          last_name: p.last_name,
          date_of_birth: p.date_of_birth,
          medical_conditions: p.medical_conditions
        }
      )
      |> Repo.all()
      |> Enum.map(fn row ->
        logged = Map.get(emails, row.id, [])

        row
        |> Map.drop([:date_of_birth, :medical_conditions])
        # A fast-track's window is the Payment Cutoff (its Contact email says so).
        |> Map.update!(:window_ends_at, &(&1 || workshop.payment_cutoff))
        |> Map.put(:minor, WorkshopPolicy.minor?(row.date_of_birth, workshop.date))
        |> Map.put(:medical, medical?(row.medical_conditions))
        |> Map.put(:refund, Map.get(refunds, row.id))
        |> Map.put(:email_log, logged ++ scheduled_emails(row, logged, workshop))
        |> Map.put(:history, Map.get(history, row.id, []))
        |> then(fn row ->
          # The rule's facts: the row plus the workshop's status (ALE-393).
          facts = Map.put(row, :workshop_status, workshop.status)

          row
          |> Map.put(:available_commands, IntakePolicy.available_commands(facts))
          |> Map.put(:attendance_corrections, IntakePolicy.attendance_corrections(facts))
        end)
      end)

    %{
      seated: Enum.filter(rows, &(&1.state == "paid")),
      asked: Enum.filter(rows, &(&1.state == "contacted")),
      attended: Enum.filter(rows, &(&1.state == "attended")),
      no_show: Enum.filter(rows, &(&1.state == "no_show")),
      out: Enum.reject(rows, &(&1.state in @not_out))
    }
  end

  defp medical?(nil), do: false
  defp medical?(conditions), do: String.trim(conditions) != ""

  # What was queued for each Intake, oldest first (queued, not delivered).
  defp email_logs(workshop_id) do
    from(l in IntakeEmailLog,
      join: i in Intake,
      on: i.id == l.intake_id,
      where: i.workshop_id == ^workshop_id,
      order_by: [asc: l.queued_at, asc: l.id],
      select:
        {l.intake_id,
         %{email_type: l.email_type, occasion: l.occasion, at: l.queued_at, scheduled: false}}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # The scheduled email still owed, by the same occasions the passes use:
  # "Pre-workshop info" for this schedule to a `paid` Intake of a scheduled
  # workshop, at the Payment Cutoff (`IntakeEmailLog.pre_workshop_occasion/1`),
  # and the Follow-up to an `attended` Intake (`WorkshopPolicy.follow_up_at/1`).
  # An `at` in the past means the next sweep.
  defp scheduled_emails(%{state: "paid"}, logged, %BeginnersWorkshop{status: "scheduled"} = w),
    do:
      owed(
        logged,
        IntakeEmailLog.pre_workshop_occasion(w.reschedule_count),
        "pre_workshop",
        w.payment_cutoff
      )

  defp scheduled_emails(
         %{state: "attended"},
         logged,
         %BeginnersWorkshop{status: "finalised"} = w
       ),
       do: owed(logged, "follow_up", "follow_up", WorkshopPolicy.follow_up_at(w))

  defp scheduled_emails(_row, _logged, _workshop), do: []

  defp owed(logged, occasion, email_type, at) do
    if Enum.any?(logged, &(&1.occasion == occasion)),
      do: [],
      else: [%{email_type: email_type, occasion: nil, at: at, scheduled: true}]
  end

  # Each Intake's history, oldest first, the actor named by their profile.
  defp histories(workshop_id) do
    from(e in IntakeEvent,
      join: i in Intake,
      on: i.id == e.intake_id,
      left_join: p in UserProfile,
      on: p.principal_id == e.actor_principal_id and not is_nil(e.actor_principal_id),
      where: i.workshop_id == ^workshop_id,
      order_by: [asc: e.occurred_at, asc: e.id],
      select:
        {e.intake_id,
         %{
           command: e.command,
           actor: fragment("nullif(trim(concat_ws(' ', ?, ?)), '')", p.first_name, p.last_name),
           occurred_at: e.occurred_at,
           note: e.note,
           correction: e.correction
         }}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # Contacted people still unpaid after their window: needs a nudge.
  # Carried Fee holders are listed apart (`unconfirmed_carried_fees`): they
  # confirm rather than pay, until finalisation.
  defp unpaid_after_window(%{asked: asked}, reading) do
    asked
    |> Enum.reject(&(&1.carried_fee == "held"))
    |> Enum.filter(&(DateTime.compare(&1.window_ends_at, reading.now) != :gt))
    |> Enum.sort_by(& &1.window_ends_at, DateTime)
    |> Enum.map(&Map.take(&1, [:id, :first_name, :last_name, :window_ends_at, :batch_number]))
  end

  # Contacted Carried Fee holders who have not confirmed: they may confirm
  # until finalisation, so the coordinator may chase them (story 66).
  defp unconfirmed_carried_fees(%{asked: asked}) do
    asked
    |> Enum.filter(&(&1.carried_fee == "held"))
    |> Enum.map(&Map.take(&1, [:id, :first_name, :last_name, :contacted_at, :batch_number]))
  end

  defp finalisation(%BeginnersWorkshop{status: "finalised"} = workshop, attended) do
    %{
      at: workshop.finalised_at,
      by: DoorView.finaliser_name(workshop.finalised_by_principal_id),
      follow_up_at: WorkshopPolicy.follow_up_at(workshop),
      invitations: %{
        attended: length(attended),
        invited: Enum.count(attended, &(&1.standing == "invited")),
        joined: Enum.count(attended, &(&1.standing == "joined"))
      }
    }
  end

  defp finalisation(%BeginnersWorkshop{}, _attended), do: nil

  defp cancel_preview(%BeginnersWorkshop{status: "scheduled"}, roster) do
    %{
      deferred: length(roster.seated),
      returned: length(roster.asked),
      released: Enum.count(roster.asked, &(not is_nil(&1.hold_expires_at)))
    }
  end

  defp cancel_preview(%BeginnersWorkshop{}, _roster), do: nil

  defp cancellation(%BeginnersWorkshop{status: "cancelled"} = workshop) do
    %{
      at: workshop.cancelled_at,
      by: name_of(workshop.cancelled_by_principal_id),
      reason: workshop.cancel_reason
    }
  end

  defp cancellation(%BeginnersWorkshop{}), do: nil

  # The latest refund of each Intake, by when it was requested.
  defp latest_refunds(workshop_id) do
    from(r in IntakeRefund,
      where: r.workshop_id == ^workshop_id,
      order_by: [asc: r.requested_at, asc: r.created_at]
    )
    |> Repo.all()
    |> Map.new(fn refund ->
      {refund.intake_id,
       %{
         status: refund.status,
         method: refund.method,
         automatic: IntakeRefund.automatic?(refund),
         amount_cents: refund.amount_cents,
         currency: refund.currency
       }}
    end)
  end

  defp failed_refunds(workshop_id) do
    from(r in IntakeRefund,
      as: :refund,
      join: i in Intake,
      on: i.id == r.intake_id,
      left_join: p in UserProfile,
      on: p.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id),
      left_join: f in IntakeRefund,
      on: f.follows_refund_id == r.id,
      left_join: fee in CarriedFee,
      on: fee.id == r.carried_fee_id,
      where: r.workshop_id == ^workshop_id and r.status == "failed" and is_nil(f.id),
      # ALE-389: a Carried Fee's failed refund needs attention while the fee
      # is still owed back (held again) and no later refund of it exists.
      where:
        is_nil(r.carried_fee_id) or
          (fee.status in ["held", "refunded"] and
             not exists(
               from(later in IntakeRefund,
                 where:
                   later.carried_fee_id == parent_as(:refund).carried_fee_id and
                     later.id != parent_as(:refund).id and
                     later.created_at > parent_as(:refund).created_at
               )
             )),
      order_by: [asc: r.failed_at, asc: r.id],
      select: %{
        id: r.id,
        intake_id: r.intake_id,
        carried_fee: not is_nil(r.carried_fee_id),
        first_name: p.first_name,
        last_name: p.last_name,
        amount_cents: r.amount_cents,
        currency: r.currency,
        reason: r.reason,
        failed_at: r.failed_at
      }
    )
    |> Repo.all()
  end

  defp attention(%{status: :due, people: []}), do: [:nobody_waiting]
  defp attention(_next_batch), do: []

  defp name_of(nil), do: nil

  defp name_of(principal_id) do
    from(p in UserProfile,
      where: p.principal_id == ^principal_id,
      limit: 1,
      select: fragment("trim(concat_ws(' ', ?, ?))", p.first_name, p.last_name)
    )
    |> Repo.one()
  end
end
