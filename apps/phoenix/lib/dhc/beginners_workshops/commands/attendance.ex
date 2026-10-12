defmodule Dhc.BeginnersWorkshops.Commands.Attendance do
  @moduledoc """
  The commands of the workshop day and after (ALE-405): `check_in` and
  `undo_check_in` (assigned Staff), the Payment Cutoff pass
  `pass_payment_cutoff`, Attendance Finalisation (`finish_workshop` by
  assigned Staff, `finalise_attendance` by the sweep), `send_follow_ups`
  and the Invitation handoff `invite` (`members.invite`).
  `Dhc.BeginnersWorkshops.Commands` authorizes the actor and routes here.

  ## Door check-in (ALE-390)

  `check_in` / `undo_check_in` (`beginners.workshops.run`) record or clear
  who checked a `paid` Intake in at the door and when — never a walk-in, and
  only while `WorkshopPolicy.check_in_window/2` is `:open` (from 1 hour
  before the start on the workshop date until Attendance Finalisation or the
  end of that Dublin day). The capability is assignment-scoped, so the actor
  is authorized against the workshop's Staff **before any read** of the
  workshop or its Intakes (a denial is `:not_found`, concealing the
  workshop), and again under the Beginners' Workshop lock, which every
  Staff change takes. The record names a Principal, not a Staff row, so it
  stays when that person is later unassigned. Both are idempotent: checking
  in a checked-in person keeps the first record. Neither is a state change;
  Attendance Finalisation turns the record into `attended` / `no_show`.

  ## Payment Cutoff (ALE-385)

  `pass_payment_cutoff` (`:system`, a sweep pass) runs for a scheduled
  workshop at or after its Payment Cutoff. Under the Beginners' Workshop
  lock, then the contacted people's Waitlist entries, the open Intakes and
  the live Seat Holds, it queues "Pre-workshop info" to every `paid` Intake
  that has not had it (log occasion `pre_workshop`, unique per Intake) and
  settles every `contacted` Intake by `WorkshopPolicy.cutoff_settlement/3`:
  `lapsed` (standing `removed` through `Dhc.Waitlist.change_standing/2`)
  when seats were free, `returned` (standing left `waiting`, so the
  original priority stands) when the workshop was full, and left alone
  while its own Seat Hold is live — the cutoff stops only new holds, so a
  later sweep settles it once Stripe ends the hold. Neither close sends an
  email. An Intake that becomes `paid` after the cutoff gets Pre-workshop
  info in the same transaction (`complete_payment`). Re-running the pass
  finds nothing owed, so it is exactly-once.

  ## Attendance Finalisation and follow-up (ALE-391)

  `finish_workshop` (assigned Staff, `beginners.workshops.run`, from the
  door once check-in has opened) and `finalise_attendance` (`:system`, a
  sweep pass once the workshop's Dublin date has ended) are the one
  Attendance Finalisation. Under the Beginners' Workshop lock, then the
  open Intakes' Waitlist entries, the open Intakes and the live Seat Holds:
  every checked-in `paid` Intake becomes `attended` (standing `attended`)
  and every other `paid` Intake `no_show` (standing `removed`, no email);
  every Intake still `contacted` is settled by the Payment Cutoff rule
  (`WorkshopPolicy.cutoff_settlement/3`) — and while one has a live Seat
  Hold the workshop is not finalised yet (Finish is refused with
  `:payment_in_progress`; the pass waits for the next sweep). Check-in
  closes with the status change, and the Staff list is frozen: each row
  keeps the person's name as it was (`frozen_name`), and `set_staff`
  refuses a finalised workshop. The workshop records when, and who pressed
  Finish (nobody, for the pass).

  `send_follow_ups` (`:system`, a sweep pass) queues "Follow-up" once to
  every `attended` Intake from 10:00 Dublin the morning after
  (`WorkshopPolicy.follow_up_at/1`; log occasion `follow_up`, unique per
  Intake), so re-running it finds nothing owed.

  ## Invitation handoff (ALE-392)

  `invite` (`members.invite`) hands one attended person to Onboarding.
  Under the Beginners' Workshop lock, then the person's Waitlist entry and
  their Intake, it refuses unless the workshop is finalised
  (`:not_finalised`), the Intake is `attended` (`:not_attended`) and the
  standing is `attended` (`:already_invited`, `:already_joined`,
  `:not_invitable`; an anonymised person is `:person_not_found`). Then it
  issues the Invitation through `Dhc.Onboarding.issue_invitation/3` (with
  `waitlist_id:`, so acceptance claims this Waitlist profile) and moves the
  standing `attended → invited`, both in this transaction. Onboarding's own
  refusals come back as `:email_is_principal`,
  `:email_has_pending_invitation` and `:incomplete_details`, and are written
  to the Invitation processing log after the rollback. The Follow-up does not
  gate it. Onboarding never calls back: deleting the Invitation returns the
  standing to `attended` on the Onboarding side (`Dhc.Invitations`).

  ## Cross-family calls

  The assignment-scoped re-check under the workshop lock (check-in,
  Finish) is `Commands.authorize_assigned/3`, the authorization the router
  ran before any read. A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      required: 1,
      transact: 1,
      transition: 3,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1]

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules,
    only: [cutoff_due?: 2, facts_for: 1, still_scheduled: 1]

  import Dhc.BeginnersWorkshops.Commands.IntakeHistory,
    only: [record_intake_event: 5]

  import Dhc.BeginnersWorkshops.Commands.IntakeNotices,
    only: [pre_workshop: 3]

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeEmails,
    IntakePayment,
    StaffAssignment,
    WorkshopFacts,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.Commands

  alias Dhc.BeginnersWorkshops.Commands.{
    Settlement
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.{Occasion}
  alias Dhc.Onboarding
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run(:system, {:pass_payment_cutoff, workshop_id}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: &cutoff_entries(&1, clock),
            intake: &cutoff_intakes/1,
            carried_fee: &held_fees_of_contacted/1,
            payment: &cutoff_holds/1
          },
          &pass_cutoff_locked(&1, clock)
        )
      end)
    end
  end

  def run({:staff, principal_id}, {:check_in, workshop_id, intake_id}, clock),
    do: door_check_in(principal_id, workshop_id, intake_id, :check_in, clock)

  def run({:staff, principal_id}, {:undo_check_in, workshop_id, intake_id}, clock),
    do: door_check_in(principal_id, workshop_id, intake_id, :undo, clock)

  def run({:staff, principal_id}, {:finish_workshop, workshop_id}, clock),
    do: finalise(workshop_id, {:staff, principal_id}, clock)

  def run(:system, {:finalise_attendance, workshop_id}, clock),
    do: finalise(workshop_id, :system, clock)

  def run(:system, {:send_follow_ups, workshop_id}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            intake: &follow_up_intakes(&1, clock)
          },
          &follow_ups_locked(&1, clock)
        )
      end)
    end
  end

  # The clock only stamps the standing change, read inside the lock.
  def run({:staff, principal_id}, {:invite, workshop_id, intake_id}, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, intake_id} <- cast_id(intake_id) do
      intake = from(i in Intake, where: i.id == ^intake_id and i.workshop_id == ^workshop_id)

      fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            # An Intake's person never changes, so the unlocked read of its
            # `waitlist_id` cannot go stale.
            waitlist_entry:
              from(e in WaitlistEntry,
                where: e.id in subquery(select(intake, [i], i.waitlist_id))
              ),
            intake: required(intake)
          },
          &invite_locked(&1, principal_id, Clock.read(clock).now)
        )
      end
      |> transact()
      |> record_invite_refusal(principal_id)
    end
  end

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── check_in / undo_check_in ────────────────────────────────────

  defp door_check_in(principal_id, workshop_id, intake_id, action, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, intake_id} <- cast_id(intake_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            intake:
              required(
                from(i in Intake, where: i.id == ^intake_id and i.workshop_id == ^workshop_id)
              )
          },
          &check_in_locked(&1, principal_id, action, clock)
        )
      end)
    end
  end

  # Staff rows change only under the workshop lock, so this re-check is
  # authoritative: someone unassigned since the pre-read check is refused.
  defp check_in_locked(%{workshop: workshop, intake: intake}, principal_id, action, clock) do
    reading = Clock.read(clock)

    with :ok <- Commands.authorize_assigned(principal_id, :"beginners.workshops.run", workshop.id),
         :ok <- check_in_window_open(workshop, reading),
         :ok <- check_in_paid(intake),
         {:ok, intake} <- record_check_in(intake, principal_id, action, reading) do
      {:ok, check_in_view(intake)}
    end
  end

  defp check_in_window_open(workshop, reading) do
    case WorkshopPolicy.check_in_window(workshop, reading) do
      :open -> :ok
      :before -> {:error, :check_in_not_open}
      :closed -> {:error, :check_in_closed}
    end
  end

  # No walk-ins: only a paid person is checked in.
  defp check_in_paid(%Intake{state: "paid"}), do: :ok
  defp check_in_paid(%Intake{}), do: {:error, :not_paid}

  # The Intake carries the current check-in (who, when); every check-in and
  # undo that changed it is also an Intake history row naming the Principal
  # and the time (story 97), so the record survives an undo and the Staff
  # member's unassignment. A repeat changes nothing and records nothing.
  defp record_check_in(%Intake{checked_in_at: %DateTime{}} = intake, _id, :check_in, _reading),
    do: {:ok, intake}

  defp record_check_in(%Intake{} = intake, principal_id, :check_in, reading) do
    with {:ok, intake} <-
           intake |> Intake.check_in_changeset(principal_id, reading.now) |> persist(),
         do: record_door_event(intake, :check_in, principal_id, reading)
  end

  defp record_check_in(%Intake{checked_in_at: nil} = intake, _id, :undo, _reading),
    do: {:ok, intake}

  defp record_check_in(%Intake{} = intake, principal_id, :undo, reading) do
    with {:ok, intake} <- intake |> Intake.undo_check_in_changeset() |> persist(),
         do: record_door_event(intake, :undo_check_in, principal_id, reading)
  end

  defp record_door_event(intake, command, principal_id, reading) do
    context = %{actor: principal_id, note: nil, options: %{}}

    with {:ok, _event} <-
           record_intake_event(intake, command, Ecto.UUID.generate(), context, reading),
         do: {:ok, intake}
  end

  defp check_in_view(%Intake{} = intake),
    do: Map.take(intake, [:id, :workshop_id, :checked_in_at, :checked_in_by_principal_id])

  # ── pass_payment_cutoff ─────────────────────────────────────────

  # Under the workshop lock: the Waitlist entries of its `contacted` people
  # (whose standing a lapse changes). Nothing is locked before the cutoff.
  defp cutoff_entries(%{workshop: workshop}, clock) do
    if cutoff_due?(workshop, Clock.read(clock)) do
      contacted =
        from(i in Intake,
          where: i.workshop_id == ^workshop.id and i.state == "contacted",
          select: i.waitlist_id
        )

      {:all, from(e in WaitlistEntry, where: e.id in subquery(contacted))}
    end
  end

  # The workshop's open Intakes, once its entries are locked.
  defp cutoff_intakes(%{workshop: workshop, waitlist_entry: entries}) when is_list(entries) do
    open = Intake.open_states()
    {:all, from(i in Intake, where: i.workshop_id == ^workshop.id and i.state in ^open)}
  end

  defp cutoff_intakes(_locked), do: nil

  # The `held` Carried Fees of the contacted people: they may still confirm
  # after the cutoff (ALE-388), so the pass leaves their Intakes open.
  defp held_fees_of_contacted(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    contacted =
      from(i in Intake,
        where: i.workshop_id == ^workshop.id and i.state == "contacted",
        select: i.waitlist_id
      )

    {:all,
     from(f in CarriedFee, where: f.status == "held" and f.waitlist_id in subquery(contacted))}
  end

  defp held_fees_of_contacted(_locked), do: nil

  # Its live Seat Holds: an Intake holding one is left for Stripe to settle.
  defp cutoff_holds(%{workshop: workshop, intake: intakes}) when is_list(intakes),
    do:
      {:all,
       from(p in IntakePayment, where: p.workshop_id == ^workshop.id and p.status == "open")}

  defp cutoff_holds(_locked), do: nil

  defp pass_cutoff_locked(%{intake: nil}, _clock), do: {:ok, %{outcome: :not_due}}

  defp pass_cutoff_locked(locked, clock) do
    %{workshop: workshop, waitlist_entry: entries, intake: intakes, payment: holds} = locked
    reading = Clock.read(clock)

    if cutoff_due?(workshop, reading) do
      pass = %{
        workshop: workshop,
        facts: facts_for(workshop),
        held: MapSet.new(holds, & &1.intake_id),
        entries: Map.new(entries, &{&1.id, &1}),
        fee_holders: MapSet.new(locked.carried_fee, & &1.waitlist_id),
        reading: reading
      }

      tally = %{outcome: :passed, pre_workshop: 0, lapsed: 0, returned: 0, awaiting_hold: 0}

      Enum.reduce_while(intakes, {:ok, tally}, fn intake, {:ok, tally} ->
        intake
        |> pass_intake(pass)
        |> count_passed(tally)
      end)
    else
      {:ok, %{outcome: :not_due}}
    end
  end

  defp count_passed({:ok, nil}, tally), do: {:cont, {:ok, tally}}

  defp count_passed({:ok, counted}, tally),
    do: {:cont, {:ok, Map.update!(tally, counted, &(&1 + 1))}}

  defp count_passed({:error, reason}, _tally), do: {:halt, {:error, reason}}

  defp pass_intake(%Intake{state: "paid"} = intake, %{workshop: workshop, reading: reading}) do
    case pre_workshop(intake, workshop, reading) do
      {:ok, :queued} -> {:ok, :pre_workshop}
      {:ok, _already_sent_or_no_recipient} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pass_intake(%Intake{state: "contacted"} = intake, pass) do
    if MapSet.member?(pass.fee_holders, intake.waitlist_id),
      do: {:ok, nil},
      else: settle_at_cutoff(intake, pass)
  end

  defp settle_at_cutoff(intake, pass) do
    hold_live? = MapSet.member?(pass.held, intake.id)

    case {entry_of(intake, pass.entries),
          WorkshopPolicy.cutoff_settlement(hold_live?, pass.workshop, pass.facts)} do
      # A person contacted after this pass peeked the entries: the next sweep.
      {:not_locked, _settlement} -> {:ok, nil}
      {_entry, :await_hold} -> {:ok, :awaiting_hold}
      {entry, settlement} -> settle_contacted(intake, entry, settlement, pass.reading)
    end
  end

  defp entry_of(%Intake{waitlist_id: nil}, _entries), do: nil
  defp entry_of(%Intake{waitlist_id: id}, entries), do: Map.get(entries, id, :not_locked)

  # A lapse or a return, counted by its name (`Commands.Settlement`'s
  # `:cutoff` rows).
  defp settle_contacted(intake, entry, settlement, reading) do
    with {:ok, _settled} <-
           Settlement.run(
             {:cutoff, settlement},
             %{waitlist_entry: entry, intake: intake},
             reading
           ),
         do: {:ok, counted(settlement)}
  end

  defp counted(:lapse), do: :lapsed
  defp counted(:return), do: :returned

  # ── finish_workshop / finalise_attendance ───────────────────────

  defp finalise(workshop_id, by, clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id) do
      transact(fn ->
        with_locked(
          %{
            workshop: required(from(w in BeginnersWorkshop, where: w.id == ^workshop_id)),
            waitlist_entry: &finalise_entries(&1, by, clock),
            intake: &finalise_intakes/1,
            carried_fee: &applied_fees/1,
            payment: &cutoff_holds/1
          },
          &finalise_locked(&1, by, clock)
        )
      end)
    end
  end

  # Under the workshop lock: the Waitlist entries of its open Intakes (whose
  # standing finalisation changes). Nothing more is locked when it may not
  # finalise now.
  defp finalise_entries(%{workshop: workshop}, by, clock) do
    if may_finalise?(workshop, by, Clock.read(clock)) do
      open =
        from(i in Intake,
          where: i.workshop_id == ^workshop.id and i.state in ^Intake.open_states(),
          select: i.waitlist_id
        )

      {:all, from(e in WaitlistEntry, where: e.id in subquery(open))}
    end
  end

  defp finalise_intakes(%{workshop: workshop, waitlist_entry: entries}) when is_list(entries),
    do:
      {:all,
       from(i in Intake,
         where: i.workshop_id == ^workshop.id and i.state in ^Intake.open_states()
       )}

  defp finalise_intakes(_locked), do: nil

  # The Carried Fees applied to the workshop's paid Intakes: spent on
  # attendance, forfeited on a no-show (ALE-367).
  defp applied_fees(%{workshop: workshop, intake: intakes}) when is_list(intakes) do
    paid =
      from(i in Intake,
        where: i.workshop_id == ^workshop.id and i.state == "paid",
        select: i.id
      )

    {:all,
     from(f in CarriedFee, where: f.status == "applied" and f.applied_intake_id in subquery(paid))}
  end

  defp applied_fees(_locked), do: nil

  defp may_finalise?(workshop, {:staff, _id}, reading),
    do: WorkshopPolicy.finish_allowed?(workshop, reading)

  defp may_finalise?(workshop, :system, reading),
    do: WorkshopPolicy.finalisation_due?(workshop, reading)

  defp finalise_locked(locked, by, clock) do
    reading = Clock.read(clock)
    workshop = locked.workshop

    with :ok <- finalise_authorized(by, workshop),
         :ok <- finalisable(workshop, by, reading) do
      finalise_now(locked, by, reading)
    end
  end

  defp finalise_now(locked, by, reading) do
    workshop = locked.workshop

    pass = %{
      workshop: workshop,
      facts: facts_for(workshop),
      held: MapSet.new(locked.payment, & &1.intake_id),
      entries: Map.new(locked.waitlist_entry, &{&1.id, &1}),
      fees: Map.new(locked.carried_fee || [], &{&1.applied_intake_id, &1}),
      reading: reading
    }

    if Enum.any?(locked.intake, &awaiting_hold?(&1, pass)),
      do: awaiting_hold(by),
      else: finalise_all(locked.intake, pass, by)
  end

  # Staff rows change only under the workshop lock, so this re-check is
  # authoritative (as for check-in).
  defp finalise_authorized({:staff, principal_id}, workshop),
    do: Commands.authorize_assigned(principal_id, :"beginners.workshops.run", workshop.id)

  defp finalise_authorized(:system, _workshop), do: :ok

  # The pass answers "not due" (it runs every sweep); Staff get a refusal.
  defp finalisable(workshop, by, reading) do
    cond do
      may_finalise?(workshop, by, reading) -> :ok
      by == :system -> {:ok, %{outcome: :not_due}}
      workshop.status != "scheduled" -> still_scheduled(workshop)
      true -> {:error, :check_in_not_open}
    end
  end

  # The cutoff rule leaves an Intake whose own Seat Hold is live for Stripe
  # to settle; finalisation waits for it rather than close a workshop with
  # someone mid-checkout.
  defp awaiting_hold?(%Intake{state: "contacted"} = intake, pass),
    do:
      WorkshopPolicy.cutoff_settlement(
        MapSet.member?(pass.held, intake.id),
        pass.workshop,
        pass.facts
      ) ==
        :await_hold

  defp awaiting_hold?(%Intake{}, _pass), do: false

  defp awaiting_hold({:staff, _id}), do: {:error, :payment_in_progress}
  defp awaiting_hold(:system), do: {:ok, %{outcome: :awaiting_hold}}

  defp finalise_all(intakes, pass, by) do
    tally = %{outcome: :finalised, attended: 0, no_show: 0, lapsed: 0, returned: 0}

    with {:ok, tally} <-
           Enum.reduce_while(intakes, {:ok, tally}, fn intake, {:ok, tally} ->
             intake |> finalise_intake(pass) |> count_passed(tally)
           end),
         :ok <- freeze_staff(pass.workshop),
         {:ok, _workshop} <-
           transition(
             :workshop,
             pass.workshop,
             BeginnersWorkshop.finalise_changeset(pass.workshop, finaliser(by), pass.reading.now)
           ) do
      {:ok, tally}
    end
  end

  defp finaliser({:staff, principal_id}), do: principal_id
  defp finaliser(:system), do: nil

  # The check-in record decides: in → `attended`, not in → `no_show`
  # (`Commands.Settlement`'s `:finalisation` rows). A person contacted
  # after the entries were locked cannot exist after the cutoff, so an
  # unlocked entry is a race: roll back and let the next attempt decide.
  defp finalise_intake(%Intake{state: "paid"} = intake, pass) do
    case entry_of(intake, pass.entries) do
      :not_locked ->
        {:error, :concurrent_change}

      entry ->
        ending = if intake.checked_in_at, do: :attended, else: :no_show

        rows = %{
          waitlist_entry: entry,
          intake: intake,
          carried_fee: Map.get(pass.fees, intake.id)
        }

        with {:ok, _settled} <- Settlement.run({:finalisation, ending}, rows, pass.reading),
             do: {:ok, ending}
    end
  end

  # Finalisation also closes any Intake still `contacted` by the cutoff rule
  # (the live-hold case never reaches here).
  defp finalise_intake(%Intake{state: "contacted"} = intake, pass) do
    case {entry_of(intake, pass.entries),
          WorkshopPolicy.cutoff_settlement(false, pass.workshop, pass.facts)} do
      {:not_locked, _settlement} -> {:error, :concurrent_change}
      {entry, settlement} -> settle_contacted(intake, entry, settlement, pass.reading)
    end
  end

  # The Staff list freezes as the permanent record (story 18): each row
  # keeps the name the person had at finalisation.
  defp freeze_staff(%BeginnersWorkshop{} = workshop) do
    names =
      from(s in StaffAssignment,
        left_join: p in UserProfile,
        on: p.principal_id == s.principal_id,
        where: s.workshop_id == ^workshop.id,
        select: {s, p.first_name, p.last_name}
      )
      |> Repo.all()

    Enum.reduce_while(names, :ok, fn {row, first, last}, :ok ->
      name = row.frozen_name || WorkshopFacts.display_name(first, last)

      case row |> StaffAssignment.freeze_changeset(name) |> persist() do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ── send_follow_ups ─────────────────────────────────────────────

  defp follow_up_intakes(%{workshop: workshop}, clock) do
    if WorkshopPolicy.follow_up_due?(workshop, Clock.read(clock)),
      do:
        {:all, from(i in Intake, where: i.workshop_id == ^workshop.id and i.state == "attended")}
  end

  defp follow_ups_locked(%{intake: nil}, _clock), do: {:ok, %{outcome: :not_due}}

  defp follow_ups_locked(%{workshop: workshop, intake: intakes}, clock) do
    reading = Clock.read(clock)

    if WorkshopPolicy.follow_up_due?(workshop, reading),
      do:
        Enum.reduce_while(
          intakes,
          {:ok, %{outcome: :sent, follow_ups: 0}},
          &follow_up(&1, &2, workshop, reading)
        ),
      else: {:ok, %{outcome: :not_due}}
  end

  defp follow_up(intake, {:ok, tally}, workshop, reading) do
    case follow_up_email(intake, workshop, reading) do
      {:ok, :queued} -> {:cont, {:ok, Map.update!(tally, :follow_ups, &(&1 + 1))}}
      {:ok, _already_sent_or_no_recipient} -> {:cont, {:ok, tally}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  # "Follow-up", once per Intake.
  defp follow_up_email(intake, workshop, reading),
    do:
      IntakeEmails.deliver(
        {:intake, intake, workshop},
        "follow_up",
        Occasion.follow_up(),
        reading
      )

  # ── invite ──────────────────────────────────────────────────────

  # The Follow-up does not gate an Invitation (story 107): attendance being
  # final is enough.
  defp invite_locked(%{workshop: workshop, waitlist_entry: entry, intake: intake}, actor_id, now) do
    with :ok <- invite_finalised(workshop),
         :ok <- invite_attended(intake),
         {:ok, entry} <- invitable(entry),
         {:ok, invite} <- invite_details(entry),
         {:ok, %{invitation_id: invitation_id}} <- issue_invitation(invite, entry, actor_id),
         {:ok, entry} <- Waitlist.change_standing(entry.id, "invited", now: now) do
      {:ok,
       %{
         intake_id: intake.id,
         workshop_id: workshop.id,
         waitlist_id: entry.id,
         invitation_id: invitation_id,
         standing: entry.status
       }}
    end
  end

  defp invite_finalised(%BeginnersWorkshop{status: "finalised"}), do: :ok
  defp invite_finalised(%BeginnersWorkshop{}), do: {:error, :not_finalised}

  defp invite_attended(%Intake{state: "attended"}), do: :ok
  defp invite_attended(%Intake{}), do: {:error, :not_attended}

  # An anonymised person has no entry, and nobody to invite.
  defp invitable(nil), do: {:error, :person_not_found}
  defp invitable(%WaitlistEntry{status: "attended"} = entry), do: {:ok, entry}
  defp invitable(%WaitlistEntry{status: "invited"}), do: {:error, :already_invited}
  defp invitable(%WaitlistEntry{status: "joined"}), do: {:error, :already_joined}
  defp invitable(%WaitlistEntry{}), do: {:error, :not_invitable}

  # The Invitation carries the Waitlist profile's details, read under the
  # entry lock (the profile is the entry's and changes with it).
  defp invite_details(%WaitlistEntry{email: nil}), do: {:error, :person_not_found}

  defp invite_details(%WaitlistEntry{id: id, email: email}) do
    case Repo.one(from(p in UserProfile, where: p.waitlist_id == ^id)) do
      nil ->
        {:error, :person_not_found}

      profile ->
        {:ok,
         %{
           "firstName" => profile.first_name,
           "lastName" => profile.last_name,
           "email" => email,
           "phoneNumber" => profile.phone_number,
           "dateOfBirth" => profile.date_of_birth,
           "pricingTier" => "standard",
           "invitationType" => "beginners_workshop"
         }}
    end
  end

  # Onboarding's refusals carry the email out of the rolled-back
  # transaction, so `record_invite_refusal/2` can log them.
  defp issue_invitation(invite, entry, actor_id) do
    case Onboarding.issue_invitation(invite, actor_id, waitlist_id: entry.id) do
      {:ok, issued} -> {:ok, issued}
      {:error, reason} -> {:error, {:invitation_refused, invite["email"], reason}}
    end
  end

  defp record_invite_refusal({:error, {:invitation_refused, email, reason}}, actor_id) do
    _ = Onboarding.record_refused_invitation(email, reason, actor_id)
    {:error, invitation_refusal(reason)}
  end

  defp record_invite_refusal(result, _actor_id), do: result

  defp invitation_refusal(:duplicate_pending_invitation), do: :email_has_pending_invitation
  defp invitation_refusal(:email_is_principal), do: :email_is_principal
  defp invitation_refusal(:email_on_waitlist), do: :email_on_waitlist
  defp invitation_refusal({:invalid_invite, _fields}), do: :incomplete_details
  # A racing issue for the same email loses on the pending-email index.
  defp invitation_refusal(_reason), do: :concurrent_change
end
