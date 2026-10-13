defmodule Dhc.BeginnersWorkshops.Commands.IntakeCommands do
  @moduledoc """
  The console Intake commands (ALE-386, ALE-405): every
  `{command, workshop_id, intake_id, attrs}` whose command is in
  `IntakePolicy.commands/0`. `Dhc.BeginnersWorkshops.Commands` authorizes
  the actor and routes here. A later Intake command joins `IntakePolicy`
  (`commands/0`, a `check/2` clause) and adds an `act_on_intake/4` clause
  here; its consequences for the person are a `Commands.Settlement` row.

  ## Console Intake commands (ALE-386)

  `decline`, `cancel_with_refund`, `withdraw`, `resend_link` and
  `rotate_link` (`beginners.workshops.manage`; `withdraw`
  `beginners.waitlist.manage`) act on one Intake of one workshop and share one plumbing,
  `intake_command/6`: every one takes an optional note, decides with
  `IntakePolicy.check/2` under the lock (the same rule the console's
  `availableCommands` comes from), and, when it acts, writes one Intake
  history row (`IntakeEvent`: command, actor, time, note) in the same
  transaction. A command whose Intake is already where it leads returns
  `ok` (`outcome: :already_done`) and writes nothing. Later Intake commands
  join `IntakePolicy` and add an `act_on_intake/4` clause.

    * `decline` locks Beginners' Workshop → the person's Waitlist entry →
      Intake → its live Seat Hold: the `contacted` Intake becomes
      `declined`, the person stays (or goes back to) `waiting` with their
      original priority, a live hold becomes `releasing` (Stripe still ends
      it; a completion that arrives anyway is refunded in full by
      `complete_payment`'s `paid_after_close` path) and "Declined" is
      queued.
    * `resend_link` sends the Intake's own email again — "Contact – pay"
      through the Batch path's `queue_contact_email/7` while `contacted`,
      "Place confirmed" while `paid` — with log occasion
      `resend_link:<event id>`. `rotate_link` first increments the link
      generation (a new token, so the old link resolves to nothing and the
      page says "no longer active"), then sends the same email
      (`rotate_link:<event id>`). Both work on open Intakes only.

    * `cancel_with_refund` (ALE-387) locks Beginners' Workshop → Waitlist
      entry → Intake → the payment that paid it: the Stripe-paid `paid`
      Intake becomes `cancelled_refunded` (its seat is free at once, since
      only `paid` Intakes and open holds count), a full refund of what that
      payment took is requested (`insert_refund/4`, the one refund-row
      writer, reason `cancelled_with_refund`, `requested_by` the actor), the
      person stays (or goes back to) `waiting` with their original priority,
      and "Cancelled with refund" is queued (occasion
      `cancelled_with_refund`).
    * `withdraw` (ALE-387, `beginners.waitlist.manage`) takes the same locks
      (the payment level is the live hold of a contacted Intake, the paying
      payment of a paid one). Contacted → `declined` (the hold becomes
      `releasing`), no email. Paid → `withdrawn`; `refund: true | false` is
      required (`:refund_choice_required`): a refund (reason `withdrawn`)
      with "Withdrawn – refunded", or a forfeit with "Withdrawn –
      forfeited" (occasion `withdrawn`). Either way the standing becomes
      `removed` through `Waitlist.change_standing/2`; `invited`/`joined`
      is `:already_invited`. The Waitlist tab's `{:withdraw, waitlist_id,
      attrs}` peeks the person's open Intake and runs exactly this under
      the lock (retrying if a Batch or Fast-track contacted them meanwhile),
      or, with none, only removes the standing. A Carried-Fee-paid Intake
      refunds or forfeits its Carried Fee instead (ALE-389).

  ## Reply Actions (ALE-411)

  `{:intake_reply, intake_reply_id}` runs `decline`, `defer`,
  `cancel_with_refund` and `resend_link` on the Intake an answered email
  was about, through the same `intake_command/6` and `IntakePolicy.check/2`
  as the console; `Commands` limits it to those (and the person-level
  `withdraw`/`refund_carried_fee`, `Commands.People`). Its context has no
  Principal (`actor: nil`) and carries `intake_reply_id`, which the history
  row records, so the console shows it as done "by email reply".

  ## Carried Fees (ALE-388)

  A Carried Fee is a prepaid seat owned by the person (`CarriedFee`); a
  person holds at most one live one. It is created `held` by `defer` on a
  Stripe-paid Intake (pointing at that Intake's payment row) or by the
  Waitlist spreadsheet import (`import_carried_fee`, `:system`, inside the
  import row's transaction), and is read under the Carried Fee lock level.

    * `defer` (`beginners.workshops.manage`, a console Intake command) locks
      Beginners' Workshop → Waitlist entry → Intake → Carried Fee: the `paid`
      Intake becomes `deferred`, the person stays (or goes back to)
      `waiting` with their original priority, a Stripe-paid Intake creates
      a `held` Carried Fee and a Carried-Fee-paid one returns its fee to
      `held`, and "Deferred" is queued.
    * A holder of a `held` Carried Fee who is contacted (a Batch, a
      fast-track, a resent link) gets "Contact – confirm (Carried Fee)".
    * `confirm` (the person, `{:intake_link, token}`, or a console Intake
      command) moves a `contacted` Intake whose person holds a `held` fee
      to `paid` (`paid_via: carried_fee`) and the fee to `applied`, in one
      transaction with no Stripe call and no Seat Hold; it is refused with
      `:full` (the same seat rule as a hold) or `:no_carried_fee`. The
      Payment Cutoff does not stop it — the cutoff pass leaves a holder's
      `contacted` Intake open, and Attendance Finalisation settles it — so it
      is allowed until finalisation. "Place confirmed – Carried Fee" is
      queued, and Pre-workshop info too when the cutoff has passed.
    * `start_payment` is refused with `:confirm_instead` for a holder, and
      `fast_track` after the cutoff places holders only.
    * Attendance Finalisation spends an `applied` fee on an attended Intake
      and forfeits it on a no-show.

  ## Carried Fee refunds and forfeits (ALE-389)

    * `refund_carried_fee` (`beginners.workshops.manage`) — a console Intake
      command (`IntakePolicy`) on any unpaid Intake of a person with a
      `held` fee, or `{:refund_carried_fee, waitlist_id, attrs}` from the
      Waitlist tab, which runs the same on their open Intake or refunds the
      fee alone (the `withdraw_person` shape). Only someone `waiting` or
      `removed` within retention (`:fee_not_refundable`); a paid Intake is
      `:already_paid`. No Intake moves, standing and priority stay, and
      "Carried Fee refunded" is queued; a contacted Intake's page then asks
      for payment, and the next Contact email is "Contact – pay".
    * `cancel_with_refund` on a Carried-Fee-paid Intake refunds its fee;
      `withdraw` needs the refund-or-forfeit choice whenever the person
      holds a fee (paid, contacted, or with no Intake — even already
      removed), and forfeit makes it `forfeited`.

  ## Attendance corrections (ALE-393)

  `correct_attendance` (`beginners.workshops.manage`, a console Intake
  command with `to`) fixes one Intake after Attendance Finalisation —
  `attended → no_show`, `no_show → attended`, or `no_show → deferred` for
  someone who told the club in time. It locks Beginners' Workshop → Waitlist
  entry → Intake → Carried Fee → the paying payment, and is refused with
  `:before_finalisation` (`:already_cancelled`), with `:already_invited`
  once the standing is `invited` or `joined`, and `:not_correctable`
  otherwise. The standing follows the lifecycle (attended → `attended`,
  no-show → `removed`, deferred → `waiting` with the original priority)
  through `Waitlist.change_standing/2`, and the Carried Fee that paid the
  Intake follows too (`spent`, `forfeited`, or `held` again on a deferral);
  a Stripe-paid no-show corrected to deferred gets a `held` Carried Fee on
  its payment, exactly as `defer` makes one, and "Deferred" is queued. A
  person corrected to attended once the Follow-up is due gets it at once
  (the same `follow_up_email/3`); before then the sweep sends it. Other
  corrections email nobody.

  ## Used by other families

    * `intake_command_context/3`, `intake_command_spec/2` and
      `intake_command_locked/4` — `Commands.People` (the Waitlist tab's
      `withdraw` and `refund_carried_fee` on an open Intake) and
      `Commands.Payments` (the person's own `confirm`);
    * `command_options/2` — `Commands.People` (`delete_person`'s
      refund-or-forfeit choice);
    * `locked_intake_facts/3` — the ALE-402 parity seam, delegated from
      `Commands`.

  A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      transact: 1,
      transition: 3,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1, fetch_attr: 2]

  import Dhc.BeginnersWorkshops.Commands.WorkshopRules,
    only: [facts_for: 1]

  import Dhc.BeginnersWorkshops.Commands.LockSpecs,
    only: [
      entry_query: 1,
      intake_spec: 2,
      locked_intake_fee: 1,
      open_payment: 1,
      paying_payment: 1
    ]

  import Dhc.BeginnersWorkshops.Commands.Facts,
    only: [fee_refund: 1, fee_refunded?: 1, read_locked: 2]

  import Dhc.BeginnersWorkshops.Commands.IntakeHistory,
    only: [command_note: 1, record_intake_event: 5]

  import Dhc.BeginnersWorkshops.Commands.IntakeNotices,
    only: [emailed: 1, place_confirmed: 3]

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    Clock,
    Intake,
    IntakeEmails,
    IntakeLink,
    IntakePolicy,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.Commands

  alias Dhc.BeginnersWorkshops.Commands.{
    Settlement
  }

  alias Dhc.BeginnersWorkshops.IntakeEmails.{Occasion}
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  # The console Intake commands: one plumbing, one rule (`IntakePolicy`).
  @intake_commands IntakePolicy.commands()

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run({:staff, principal_id}, {command, workshop_id, intake_id, attrs}, clock)
      when command in @intake_commands and is_map(attrs),
      do: intake_command(command, principal_id, workshop_id, intake_id, attrs, clock)

  # ALE-411: a Reply Action on the Intake the reply was about. `Commands`
  # has already limited the actor to its Reply Action commands.
  def run({:intake_reply, _id} = actor, {command, workshop_id, intake_id, attrs}, clock)
      when command in @intake_commands and is_map(attrs),
      do: intake_command(command, actor, workshop_id, intake_id, attrs, clock)

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── Console Intake commands (ALE-386) ───────────────────────────

  # The shared plumbing of every console Intake command: an optional note,
  # one locked re-read, `IntakePolicy.check/2` deciding, the command's own
  # act, and one history row when it acted. A repeat that finds the Intake
  # already where the command leads succeeds and writes nothing.
  defp intake_command(command, principal_id, workshop_id, intake_id, attrs, clock) do
    with {:ok, context} <- intake_command_context(command, principal_id, attrs),
         {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, peek} <- peek_console_intake(workshop_id, intake_id) do
      transact(fn ->
        with_locked(
          intake_command_spec(command, peek),
          &intake_command_locked(&1, command, context, clock)
        )
      end)
    end
  end

  # Who runs the command, their optional note, and the command's own
  # options, all checked before any lock. `by` is the Principal's id (`nil`
  # for the person themself) or, for a Reply Action (ALE-411),
  # `{:intake_reply, id}`: no Principal, and the history row names the reply.
  @doc false
  def intake_command_context(command, by, attrs) do
    with {:ok, note} <- command_note(attrs),
         {:ok, options} <- command_options(command, attrs) do
      {:ok, Map.merge(%{note: note, options: options}, by(by))}
    end
  end

  defp by({:intake_reply, reply_id}), do: %{actor: nil, intake_reply_id: reply_id}
  defp by(principal_id), do: %{actor: principal_id, intake_reply_id: nil}

  # `withdraw` (ALE-387) takes the refund-or-forfeit choice: absent, or a
  # boolean. Whether it is *required* depends on the locked Intake.
  # `delete_person` (ALE-396) takes the same choice for a Carried Fee.
  @doc false
  def command_options(command, attrs) when command in [:withdraw, :delete_person] do
    case fetch_attr(attrs, :refund) do
      refund when is_nil(refund) or is_boolean(refund) -> {:ok, %{refund: refund}}
      _other -> {:error, :invalid_refund_choice}
    end
  end

  # `correct_attendance` (ALE-393) names the state the Intake becomes.
  def command_options(:correct_attendance, attrs) do
    case fetch_attr(attrs, :to) do
      to when is_binary(to) ->
        if to in IntakePolicy.correction_states(),
          do: {:ok, %{to: to}},
          else: {:error, :invalid_correction}

      _other ->
        {:error, :invalid_correction}
    end
  end

  def command_options(_command, _attrs), do: {:ok, %{}}

  # Unlocked: which person the Intake is (to lock their Waitlist entry
  # before the Intake). An Intake never changes workshop or person; only
  # anonymisation nulls the person, which the locked re-read sees.
  defp peek_console_intake(workshop_id, intake_id) do
    with {:ok, intake_id} <- Ecto.UUID.cast(intake_id),
         %{} = peek <-
           Repo.one(
             from(i in Intake,
               where: i.id == ^intake_id and i.workshop_id == ^workshop_id,
               select: %{intake_id: i.id, workshop_id: i.workshop_id, waitlist_id: i.waitlist_id}
             )
           ) do
      {:ok, peek}
    else
      _ -> {:error, :intake_not_found}
    end
  end

  # `decline` changes the person's standing and may release their hold, so
  # it locks the Waitlist entry and the live Seat Hold too.
  @doc false
  def intake_command_spec(:decline, %{waitlist_id: waitlist_id} = peek) do
    peek
    |> intake_spec(open_payment(peek.intake_id))
    |> Map.put(
      :waitlist_entry,
      waitlist_id && from(e in WaitlistEntry, where: e.id == ^waitlist_id)
    )
  end

  # `defer` returns the person to `waiting` and carries their fee: it locks
  # their entry, their Carried Fee and the payment that paid a Stripe-paid
  # Intake (the fee points at it); `confirm` applies the fee.
  def intake_command_spec(:defer, peek) do
    peek
    |> intake_spec(paying_payment(peek.intake_id))
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  def intake_command_spec(:confirm, peek),
    do: peek |> intake_spec(nil) |> Map.put(:carried_fee, &locked_intake_fee/1)

  # `cancel_with_refund` refunds the money that paid the Intake and puts
  # the person back to `waiting`, so it locks their entry, their Carried Fee
  # (ALE-389: the one that paid a Carried-Fee-paid Intake) and the payment
  # that paid a Stripe-paid one. A Carried Fee's original payment row is
  # never edited, so its refund reads it without a lock; the fee lock
  # serialises every refund of the fee.
  def intake_command_spec(:cancel_with_refund, peek) do
    peek
    |> intake_spec(paying_payment(peek.intake_id))
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  # `withdraw` removes the person and settles their money; which payment it
  # locks depends on the locked Intake: a contacted one's live hold, a paid
  # one's payment; and (ALE-389) the person's Carried Fee.
  def intake_command_spec(:withdraw, peek) do
    peek
    |> intake_spec(fn
      %{intake: %Intake{state: "contacted"}} -> open_payment(peek.intake_id)
      %{intake: %Intake{state: "paid"}} -> paying_payment(peek.intake_id)
      _closed -> nil
    end)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  # ALE-389: refunding the person's Carried Fee locks their entry and the fee.
  def intake_command_spec(:refund_carried_fee, peek) do
    peek
    |> intake_spec(nil)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &locked_intake_fee/1)
  end

  # `correct_attendance` (ALE-393) moves the standing and the Carried Fee
  # that paid the Intake (or, for a Stripe payer's deferral, makes one on the
  # paying payment, so it locks the person's live fee and that payment).
  def intake_command_spec(:correct_attendance, peek) do
    peek
    |> intake_spec(fn
      %{intake: %Intake{paid_via: "stripe"}} -> paying_payment(peek.intake_id)
      _carried_fee_paid -> nil
    end)
    |> Map.put(:waitlist_entry, entry_query(peek))
    |> Map.put(:carried_fee, &correction_fee/1)
  end

  def intake_command_spec(_link_command, peek), do: intake_spec(peek, nil)

  @doc false
  def intake_command_locked(%{intake: intake} = locked, command, context, clock) do
    reading = Clock.read(clock)
    facts = policy_facts(locked, context, reading)

    case IntakePolicy.check(command, facts) do
      :ok ->
        event_id = Ecto.UUID.generate()
        locked = Map.merge(locked, %{context: context, facts: facts})

        with {:ok, intake} <- act_on_intake(command, locked, event_id, reading),
             {:ok, _event} <- record_intake_event(intake, command, event_id, context, reading) do
          {:ok, intake_command_view(intake, :done)}
        end

      :already_done ->
        {:ok, intake_command_view(intake, :already_done)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What each closing does to the person is its `Commands.Settlement` row;
  # the command only names it.
  defp act_on_intake(:decline, locked, _event_id, reading),
    do: settle({:decline, :contacted}, hold_rows(locked), reading)

  # A deferral keeps the person's money as a Carried Fee and their place in
  # the queue (story 69).
  defp act_on_intake(:defer, locked, _event_id, reading),
    do: settle({:defer, :paid}, locked, reading)

  # ALE-387: a paid person wants their money back (ALE-389: a
  # Carried-Fee-paid Intake refunds the Carried Fee).
  defp act_on_intake(:cancel_with_refund, %{intake: intake} = locked, _event_id, reading),
    do: settle({:cancel_with_refund, Settlement.paid_by(intake)}, locked, reading)

  # Takes a seat under the workshop lock with the same rule as a Seat Hold,
  # but needs no hold: nothing outside this transaction is called. The
  # Payment Cutoff does not stop it (only new Stripe holds); finalisation
  # closes the Intake, which ends it.
  defp act_on_intake(:confirm, locked, _event_id, reading) do
    %{workshop: workshop, intake: intake, carried_fee: fee} = locked

    cond do
      workshop.status != "scheduled" ->
        {:error, :intake_closed}

      not WorkshopPolicy.seat_free?(workshop, facts_for(workshop)) ->
        {:error, :full}

      true ->
        with {:ok, intake} <-
               transition(
                 :intake,
                 intake,
                 Intake.paid_changeset(intake, {"carried_fee", fee.id}, reading.now)
               ),
             {:ok, _fee} <-
               transition(
                 :carried_fee,
                 fee,
                 CarriedFee.status_changeset(fee, "applied", intake.id, reading.now)
               ),
             :ok <- place_confirmed(intake, workshop, reading) do
          {:ok, intake}
        end
    end
  end

  # ALE-387: the person leaves the Waitlist. Money is never handled
  # implicitly: a paid Intake, and (ALE-389) any Carried Fee the person
  # holds, needs the refund-or-forfeit choice, and the person is told which.
  defp act_on_intake(:withdraw, %{intake: %Intake{state: "contacted"}} = locked, _id, reading),
    do: settle({:withdraw, :contacted}, hold_rows(locked), reading)

  defp act_on_intake(
         :withdraw,
         %{intake: %Intake{state: "paid"} = intake} = locked,
         _id,
         reading
       ),
       do: settle({:withdraw, Settlement.paid_by(intake)}, locked, reading)

  # ALE-389: the person's `held` Carried Fee is refunded; nothing else
  # moves (a contacted Intake now asks for payment).
  defp act_on_intake(:refund_carried_fee, locked, _event_id, reading),
    do: settle({:refund_carried_fee, :open_intake}, locked, reading)

  defp act_on_intake(:resend_link, %{workshop: workshop, intake: intake}, event_id, reading) do
    with :ok <-
           emailed(
             IntakeEmails.deliver(
               {:intake, intake, workshop},
               :link,
               Occasion.resend_link(event_id),
               reading
             )
           ),
         do: {:ok, intake}
  end

  defp act_on_intake(:rotate_link, %{workshop: workshop, intake: intake}, event_id, reading) do
    token = IntakeLink.token(intake.id, intake.link_generation + 1)

    with {:ok, intake} <-
           intake |> Intake.rotate_link_changeset(IntakeLink.hash(token)) |> persist(),
         :ok <-
           emailed(
             IntakeEmails.deliver(
               {:intake, intake, workshop},
               :link,
               Occasion.rotate_link(event_id),
               reading
             )
           ) do
      {:ok, intake}
    end
  end

  # ALE-393: fix a door mistake, or turn a no-show into a Deferral.
  defp act_on_intake(:correct_attendance, locked, _event_id, reading) do
    %{waitlist_entry: entry, intake: intake, context: context} = locked
    to = context.options.to

    with :ok <- no_other_open_intake(entry, intake, to),
         {:ok, intake} <- settle({:correct_attendance, to}, locked, reading) do
      {:ok, intake}
    else
      # The person's record moved on since finalisation (a refunded fee,
      # another live fee, a standing the table cannot reach from here): the
      # correction no longer fits, so it is refused by name.
      {:error, reason} when reason in [:illegal_transition, :illegal_standing_change] ->
        {:error, :not_correctable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An Intake command's Settlement, against its locked rows, with the
  # actor, the refund-or-forfeit choice and the facts that say whether the
  # choice is required.
  defp settle(key, %{context: context, facts: facts} = locked, reading) do
    with {:ok, %{intake: intake}} <-
           Settlement.run(key, locked, reading,
             actor: context.actor,
             choice: Map.get(context.options, :refund),
             facts: facts
           ),
         do: {:ok, intake}
  end

  # `decline` and a contacted `withdraw` lock the Intake's live Seat Hold
  # as its payment.
  defp hold_rows(%{payment: hold} = locked),
    do: %{locked | payment: nil} |> Map.put(:holds, List.wrap(hold))

  # What `IntakePolicy.check/2` reads (`IntakePolicy.facts/1`): the locked
  # Intake and workshop and, for the commands that lock them, the person's
  # standing and live Carried Fee (with its latest refund), whether their
  # latest fee was refunded, and a correction's target (ALE-393).
  defp policy_facts(%{intake: intake} = locked, context, reading) do
    fee = live_fee(Map.get(locked, :carried_fee))

    IntakePolicy.facts(
      intake: intake,
      entry: Map.get(locked, :waitlist_entry),
      carried_fee: fee,
      carried_fee_refund: fee_refund(fee),
      latest_fee_refunded:
        fee == nil and is_binary(intake.waitlist_id) and fee_refunded?(intake.waitlist_id),
      workshop_status: locked.workshop.status,
      correction: Map.get(context.options, :to),
      now: reading.now
    )
  end

  # `correct_attendance` locks the fee that paid the Intake, which is no
  # longer live once it is spent or forfeited.
  defp live_fee(%CarriedFee{status: status} = fee) do
    if status in CarriedFee.live_statuses(), do: fee
  end

  defp live_fee(nil), do: nil

  @doc false
  # ALE-402 parity seam: the facts the boundary decides an Intake command
  # by, from the locked read with the widest Intake lock set (entry and
  # live Carried Fee, as `refund_carried_fee` takes them) and no correction.
  # Nothing is written.
  @spec locked_intake_facts(binary(), binary(), Clock.t()) ::
          {:ok, IntakePolicy.t()} | {:error, term()}
  def locked_intake_facts(workshop_id, intake_id, %Clock{} = clock) do
    with {:ok, workshop_id} <- cast_id(workshop_id),
         {:ok, peek} <- peek_console_intake(workshop_id, intake_id) do
      read_locked(intake_command_spec(:refund_carried_fee, peek), fn locked ->
        policy_facts(locked, %{options: %{}}, Clock.read(clock))
      end)
    end
  end

  defp intake_command_view(%Intake{} = intake, outcome) do
    intake
    |> Map.take([:id, :workshop_id, :state, :link_generation])
    |> Map.put(:outcome, outcome)
  end

  # ── correct_attendance (ALE-393) ────────────────────────────────

  # The Carried Fee that paid the Intake; a Stripe payer's live one (which a
  # deferral would have to be the only one of).
  defp correction_fee(%{intake: %Intake{carried_fee_id: id}}) when is_binary(id),
    do: from(f in CarriedFee, where: f.id == ^id)

  defp correction_fee(locked), do: locked_intake_fee(locked)

  # An attendee is no longer on the Waitlist, so someone who has since been
  # placed in another workshop cannot become one here. Every Intake is
  # created under the person's entry lock, which this command holds.
  defp no_other_open_intake(%WaitlistEntry{id: waitlist_id}, %Intake{id: intake_id}, "attended") do
    if Repo.exists?(
         from(i in Intake,
           where:
             i.waitlist_id == ^waitlist_id and i.id != ^intake_id and
               i.state in ^Intake.open_states()
         )
       ),
       do: {:error, :open_intake},
       else: :ok
  end

  defp no_other_open_intake(_entry, _intake, _to), do: :ok
end
