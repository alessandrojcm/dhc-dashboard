defmodule Dhc.BeginnersWorkshops.Commands.People do
  @moduledoc """
  The person-level commands of the Waitlist tab and the sweep (ALE-405):
  `withdraw` and `refund_carried_fee` naming a person (`{command,
  waitlist_id, attrs}`), `link_carried_fee_payment`, `delete_person`,
  `purge_retention` and `import_carried_fee`.
  `Dhc.BeginnersWorkshops.Commands` authorizes the actor and routes here.

  ## Withdraw from the Waitlist tab (ALE-387)

  The Waitlist tab's `{:withdraw, waitlist_id, attrs}`
  (`beginners.waitlist.manage`) peeks the person's open Intake and runs
  exactly the console's `withdraw` on it under the lock (retrying if a
  Batch or Fast-track contacted them meanwhile), or, with none, only
  removes the standing (`IntakePolicy.check(:withdraw, _)` with no Intake).
  A held Carried Fee needs the refund-or-forfeit choice either way.

  ## Carried Fees (ALE-388, ALE-389)

  `import_carried_fee` (`:system`) creates a `held` Carried Fee from the
  Waitlist spreadsheet import's Paid cell, inside the import row's
  transaction; a person who already holds a live fee keeps it.

    * `refund_carried_fee` (`beginners.workshops.manage`) — a console Intake
      command (`IntakePolicy`) on any unpaid Intake of a person with a
      `held` fee, or `{:refund_carried_fee, waitlist_id, attrs}` from the
      Waitlist tab, which runs the same on their open Intake or refunds the
      fee alone (the `withdraw_person` shape). Only someone `waiting` or
      `removed` within retention (`:fee_not_refundable`); a paid Intake is
      `:already_paid`. No Intake moves, standing and priority stay, and
      "Carried Fee refunded" is queued; a contacted Intake's page then asks
      for payment, and the next Contact email is "Contact – pay".
    * `link_carried_fee_payment` reads an imported fee's PaymentIntent from
      Stripe between transactions (`IntakeRefunds.original_payment/1`: a
      `succeeded`, unrefunded payment) and records it with Stripe's amount
      under the entry → Carried Fee locks.

  ## Hard delete: retention purge and manual delete (ALE-396)

  `delete_person` (`beginners.waitlist.manage`, the Waitlist tab's Delete)
  and `purge_retention` (`:system`, a sweep pass, one person per command)
  are the one hard delete. Under the person's Waitlist entry lock, then
  every Intake they ever had, then their live Carried Fee:

    * `delete_person` is refused with `:open_intake` and with
      `:not_deletable` (standing `invited` or `joined`, a claimed profile, or
      an Invitation that still names them); a Carried Fee needs the
      refund-or-forfeit choice first (`:refund_choice_required`), refunded in
      full against its original payment (reason `deleted`) or forfeited.
      It emails nobody.
    * `purge_retention` acts only on someone `removed` for more than the
      3-month retention window (`Waitlist.restorable?/2` on the boundary
      clock, under the lock) with no open Intake, and forfeits any `held`
      Carried Fee; anything else is `:not_due`.
    * Both anonymise the person's Intakes (`waitlist_id` null,
      `anonymised_at`), each keeping its queue date; an `attended` one first
      records `invitation_outcome` (`not_invited`, `invited`, `joined`).
      Every Carried Fee row of the person is kept with no link to them, and
      refund rows (which never named the person) stay. Then
      `Dhc.Waitlist.hard_delete/1` deletes the Guardian, the unclaimed
      UserProfile and the Waitlist entry.

  ## Cross-family calls

  An open Intake's `withdraw` and `refund_carried_fee`, and
  `delete_person`'s refund choice, go through `Commands.IntakeCommands`
  (`intake_command_context/3`, `intake_command_spec/2`,
  `intake_command_locked/4`, `command_options/2`). `locked_carried_fee_facts/2`
  is the ALE-402 parity seam, delegated from `Commands`. A family never calls another family's private functions (ALE-405).
  """

  import Ecto.Query

  import Dhc.BeginnersWorkshops.Commands.Protocol,
    only: [
      persist: 1,
      required: 1,
      transact: 1,
      with_locked: 2
    ]

  import Dhc.BeginnersWorkshops.Commands.Input,
    only: [cast_id: 1, cast_person_id: 1, fetch_attr: 2]

  import Dhc.BeginnersWorkshops.Commands.LockSpecs,
    only: [live_fee_query: 1]

  import Dhc.BeginnersWorkshops.Commands.Facts,
    only: [fee_refund: 1, fee_refunded?: 1, latest_fee: 1, read_locked: 2]

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    CarriedFeePolicy,
    Clock,
    Intake,
    IntakePayment,
    IntakePolicy,
    IntakeRefunds
  }

  alias Dhc.BeginnersWorkshops.Commands

  alias Dhc.BeginnersWorkshops.Commands.{
    IntakeCommands,
    Settlement
  }

  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.WaitlistEntry

  # A Waitlist-tab command that loses the person's open Intake to a
  # concurrent command retries from a fresh peek this many times (as many
  # as a Batch pass).
  @batch_attempts 3

  @doc false
  @spec run(Commands.actor(), Commands.command(), Clock.t()) ::
          {:ok, term()} | {:error, Commands.error()}
  def run(:system, {:import_carried_fee, waitlist_id, paid_text}, clock)
      when is_binary(paid_text),
      do: import_carried_fee(waitlist_id, paid_text, clock)

  # ALE-389: the Waitlist tab's Refund Carried Fee names the person.
  def run({:staff, principal_id}, {:refund_carried_fee, waitlist_id, attrs}, clock)
      when is_map(attrs),
      do: refund_person_fee(principal_id, waitlist_id, attrs, clock)

  def run({:staff, _principal_id}, {:link_carried_fee_payment, waitlist_id, attrs}, clock)
      when is_map(attrs),
      do: link_fee_payment(waitlist_id, attrs, clock)

  # ALE-396: the Waitlist tab's Delete, and the sweep's retention purge.
  def run({:staff, principal_id}, {:delete_person, waitlist_id, attrs}, clock)
      when is_map(attrs),
      do: delete_person(principal_id, waitlist_id, attrs, clock)

  def run(:system, {:purge_retention, waitlist_id}, clock),
    do: purge_retention(waitlist_id, clock)

  # ALE-387: the Waitlist tab's withdraw names the person, not an Intake.
  def run({:staff, principal_id}, {:withdraw, waitlist_id, attrs}, clock) when is_map(attrs),
    do: withdraw_person(principal_id, waitlist_id, attrs, clock)

  def run(_actor, _command, _clock), do: {:error, :unknown_command}

  # ── withdraw from the Waitlist tab (ALE-387) ───────────────────

  # The Waitlist tab names the person. With an open Intake this is exactly
  # the console's `withdraw` on it (same lock order, rule and history row);
  # without one only the standing changes. The open Intake is peeked
  # unlocked, so a Batch or Fast-track that contacts the person meanwhile
  # is caught under the lock and the attempt retries from a fresh peek.
  defp withdraw_person(principal_id, waitlist_id, attrs, clock) do
    with {:ok, context} <- IntakeCommands.intake_command_context(:withdraw, principal_id, attrs),
         {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      withdraw_person_attempt(waitlist_id, context, clock, @batch_attempts)
    end
  end

  defp withdraw_person_attempt(waitlist_id, context, clock, attempts) do
    case transact(fn -> withdraw_person_locked(waitlist_id, context, clock) end) do
      {:error, :concurrent_change} when attempts > 1 ->
        withdraw_person_attempt(waitlist_id, context, clock, attempts - 1)

      result ->
        result
    end
  end

  defp withdraw_person_locked(waitlist_id, context, clock) do
    case peek_open_intake(waitlist_id) do
      nil ->
        with_locked(
          %{
            waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
            carried_fee: live_fee_query(waitlist_id)
          },
          &withdraw_standing(&1, waitlist_id, context, clock)
        )

      peek ->
        with_locked(
          IntakeCommands.intake_command_spec(:withdraw, peek),
          &withdraw_open_intake(&1, waitlist_id, context, clock)
        )
    end
  end

  defp peek_open_intake(waitlist_id) do
    Repo.one(
      from(i in Intake,
        where: i.waitlist_id == ^waitlist_id and i.state in ^Intake.open_states(),
        select: %{intake_id: i.id, workshop_id: i.workshop_id, waitlist_id: i.waitlist_id}
      )
    )
  end

  defp open_intake_of?(%{waitlist_entry: %WaitlistEntry{}, intake: %Intake{} = intake}, id),
    do: intake.waitlist_id == id and intake.state in Intake.open_states()

  defp open_intake_of?(_locked, _id), do: false

  # The peeked Intake must still be this person's open one under the lock.
  defp withdraw_open_intake(locked, waitlist_id, context, clock) do
    with true <- open_intake_of?(locked, waitlist_id) || {:error, :concurrent_change},
         {:ok, view} <- IntakeCommands.intake_command_locked(locked, :withdraw, context, clock) do
      {:ok, withdraw_person_view(Repo.reload!(locked.waitlist_entry), view)}
    end
  end

  # No open Intake: `IntakePolicy.check(:withdraw, _)` with no Intake
  # (ALE-402) over the standing, under the entry lock, and (ALE-389) the
  # person's live Carried Fee, which needs the refund-or-forfeit choice even
  # when they are already removed. An Intake created since the peek (it
  # takes this lock too) is found here.
  defp withdraw_standing(%{waitlist_entry: nil}, _waitlist_id, _context, _clock),
    do: {:error, :person_not_found}

  defp withdraw_standing(%{waitlist_entry: entry, carried_fee: fee}, waitlist_id, context, clock) do
    reading = Clock.read(clock)
    facts = person_facts(entry, fee, reading)

    cond do
      peek_open_intake(waitlist_id) != nil ->
        {:error, :concurrent_change}

      IntakePolicy.check(:withdraw, facts) == :already_done ->
        {:ok, withdraw_person_view(entry, nil, :already_done)}

      true ->
        with {:ok, _settled} <-
               Settlement.run(
                 {:withdraw, :no_intake},
                 %{waitlist_entry: entry, carried_fee: fee},
                 reading,
                 actor: context.actor,
                 choice: context.options.refund,
                 facts: facts
               ),
             do: {:ok, withdraw_person_view(Repo.reload!(entry), nil, :done)}
    end
  end

  # `IntakePolicy`'s facts of a person with no open Intake: their locked
  # entry and live Carried Fee.
  defp person_facts(entry, fee, reading) do
    IntakePolicy.facts(
      intake: nil,
      entry: entry,
      carried_fee: fee,
      carried_fee_refund: fee_refund(fee),
      latest_fee_refunded: fee == nil and fee_refunded?(entry.id),
      workshop_status: nil,
      correction: nil,
      now: reading.now
    )
  end

  defp withdraw_person_view(entry, intake_view),
    do: withdraw_person_view(entry, intake_view, intake_view.outcome)

  defp withdraw_person_view(%WaitlistEntry{} = entry, intake_view, outcome),
    do: %{waitlist_id: entry.id, status: entry.status, intake: intake_view, outcome: outcome}

  # ── Hard delete: delete_person and purge_retention (ALE-396) ───

  # The person's rows a hard delete changes: their entry, every Intake they
  # ever had (anonymised), and their live Carried Fee (refunded or
  # forfeited first). Every Intake is created under the person's entry lock,
  # so no new one can appear while it is held.
  defp person_delete_spec(waitlist_id) do
    %{
      waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
      intake: {:all, from(i in Intake, where: i.waitlist_id == ^waitlist_id)},
      carried_fee: live_fee_query(waitlist_id)
    }
  end

  # The coordinator's delete, at any time on request: refused with an open
  # Intake or once the Invitation handoff is under way; a Carried Fee needs
  # the refund-or-forfeit choice first. Deletion emails nobody.
  defp delete_person(principal_id, waitlist_id, attrs, clock) do
    with {:ok, %{refund: refund}} <- IntakeCommands.command_options(:delete_person, attrs),
         {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      transact(fn ->
        with_locked(
          person_delete_spec(waitlist_id),
          &delete_person_locked(&1, principal_id, refund, clock)
        )
      end)
    end
  end

  defp delete_person_locked(%{waitlist_entry: nil}, _principal_id, _refund, _clock),
    do: {:error, :person_not_found}

  defp delete_person_locked(locked, principal_id, refund, clock) do
    %{waitlist_entry: entry, intake: intakes, carried_fee: fee} = locked
    reading = Clock.read(clock)

    with :ok <- none_open(intakes),
         :ok <- deletable_standing(entry),
         {:ok, %{carried_fee: fee}} <-
           Settlement.run(
             {:delete_person, :deleted},
             %{waitlist_entry: entry, carried_fee: fee},
             reading,
             actor: principal_id,
             choice: refund
           ),
         {:ok, anonymised} <- hard_delete(entry, intakes, reading) do
      {:ok, deleted_view(entry, anonymised, fee, :deleted)}
    end
  end

  defp none_open(intakes) do
    if Enum.any?(intakes, &(&1.state in Intake.open_states())),
      do: {:error, :open_intake},
      else: :ok
  end

  # An Invitation already under way, or a Member, belongs to Onboarding.
  defp deletable_standing(%WaitlistEntry{status: status}) when status in ~w(invited joined),
    do: {:error, :not_deletable}

  defp deletable_standing(%WaitlistEntry{}), do: :ok

  # The time-driven purge (`:system`, a sweep pass): someone `removed` for
  # more than the 3-month retention window — judged with the boundary
  # clock under the entry lock — is hard-deleted and any `held` Carried Fee
  # forfeited. A removed person whose Intake is still open (staff removed
  # them while contacted) waits until it closes.
  defp purge_retention(waitlist_id, clock) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      transact(fn -> with_locked(person_delete_spec(waitlist_id), &purge_locked(&1, clock)) end)
    end
  end

  defp purge_locked(%{waitlist_entry: nil}, _clock), do: {:ok, %{outcome: :not_due}}

  defp purge_locked(%{waitlist_entry: entry, intake: intakes, carried_fee: fee}, clock) do
    reading = Clock.read(clock)

    if retention_ended?(entry, reading) and none_open(intakes) == :ok do
      with {:ok, %{carried_fee: fee}} <-
             Settlement.run(
               {:purge_retention, :purged},
               %{waitlist_entry: entry, carried_fee: fee},
               reading
             ),
           {:ok, anonymised} <- hard_delete(entry, intakes, reading),
           do: {:ok, deleted_view(entry, anonymised, fee, :purged)}
    else
      {:ok, %{waitlist_id: entry.id, outcome: :not_due}}
    end
  end

  defp retention_ended?(%WaitlistEntry{status: "removed", removed_at: %DateTime{} = at}, reading),
    do: not Waitlist.restorable?(at, reading.now)

  defp retention_ended?(%WaitlistEntry{}, _reading), do: false

  # The one hard delete: the person's Intakes are anonymised (each keeps its
  # queue date; an attended one first records whether the person had been
  # invited or had joined), every Carried Fee row of theirs is kept with no
  # link to them, and the Waitlist deletes the entry, the unclaimed
  # UserProfile and the Guardian.
  defp hard_delete(%WaitlistEntry{} = entry, intakes, reading) do
    outcome = invitation_outcome(entry)

    with {:ok, anonymised} <- anonymise_intakes(intakes, outcome, reading),
         {_count, _rows} <-
           Repo.update_all(from(f in CarriedFee, where: f.waitlist_id == ^entry.id),
             set: [waitlist_id: nil, updated_at: reading.now]
           ),
         :ok <- Waitlist.hard_delete(entry.id) do
      {:ok, anonymised}
    end
  end

  defp invitation_outcome(%WaitlistEntry{status: "invited"}), do: "invited"
  defp invitation_outcome(%WaitlistEntry{status: "joined"}), do: "joined"
  defp invitation_outcome(%WaitlistEntry{}), do: "not_invited"

  defp anonymise_intakes(intakes, outcome, reading) do
    Enum.reduce_while(intakes, {:ok, 0}, fn intake, {:ok, count} ->
      recorded = if intake.state == "attended", do: outcome

      case intake |> Intake.anonymise_changeset(recorded, reading.now) |> persist() do
        {:ok, _intake} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deleted_view(entry, anonymised, fee, outcome) do
    %{
      waitlist_id: entry.id,
      anonymised_intakes: anonymised,
      carried_fee: fee && Map.take(fee, [:id, :status]),
      outcome: outcome
    }
  end

  # The Waitlist spreadsheet import's Paid cell (ALE-376): a `held` fee whose
  # original payment is the imported record. Runs inside the import row's
  # transaction; a person who already holds a live fee keeps it.
  defp import_carried_fee(waitlist_id, paid_text, clock) do
    with {:ok, waitlist_id} <- cast_id(waitlist_id) do
      transact(fn ->
        with_locked(
          %{
            waitlist_entry: required(from(e in WaitlistEntry, where: e.id == ^waitlist_id)),
            carried_fee: live_fee_query(waitlist_id)
          },
          &import_fee_locked(&1, paid_text, clock)
        )
      end)
    end
  end

  defp import_fee_locked(%{carried_fee: %CarriedFee{} = fee}, _paid_text, _clock),
    do: {:ok, %{outcome: :already_held, id: fee.id, status: fee.status}}

  defp import_fee_locked(%{waitlist_entry: entry}, paid_text, clock) do
    with {:ok, fee} <-
           %{
             waitlist_id: entry.id,
             imported_paid_text: paid_text,
             status_changed_at: Clock.read(clock).now
           }
           |> CarriedFee.import_changeset()
           |> persist() do
      {:ok, %{outcome: :created, id: fee.id, status: fee.status}}
    end
  end

  # ── Carried Fee refunds and forfeits (ALE-389) ─────────────────

  # The Waitlist tab names the person. With an open Intake this is exactly
  # the console's `refund_carried_fee` on it (same locks, rule and history
  # row); without one the fee alone is refunded under the person's entry
  # lock, the refund recorded on the fee's original Intake (if any). The
  # open Intake is peeked unlocked, so one created meanwhile makes the
  # attempt retry from a fresh peek — the `withdraw_person/4` shape.
  defp refund_person_fee(principal_id, waitlist_id, attrs, clock) do
    with {:ok, context} <-
           IntakeCommands.intake_command_context(:refund_carried_fee, principal_id, attrs),
         {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      refund_person_fee_attempt(waitlist_id, context, clock, @batch_attempts)
    end
  end

  defp refund_person_fee_attempt(waitlist_id, context, clock, attempts) do
    case transact(fn -> refund_person_fee_locked(waitlist_id, context, clock) end) do
      {:error, :concurrent_change} when attempts > 1 ->
        refund_person_fee_attempt(waitlist_id, context, clock, attempts - 1)

      result ->
        result
    end
  end

  defp refund_person_fee_locked(waitlist_id, context, clock) do
    case peek_open_intake(waitlist_id) do
      nil ->
        with_locked(
          %{
            waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
            carried_fee: live_fee_query(waitlist_id)
          },
          &refund_fee_alone(&1, waitlist_id, context, clock)
        )

      peek ->
        with_locked(
          IntakeCommands.intake_command_spec(:refund_carried_fee, peek),
          &refund_open_intake_fee(&1, waitlist_id, context, clock)
        )
    end
  end

  # The peeked Intake must still be this person's open one under the lock.
  defp refund_open_intake_fee(locked, waitlist_id, context, clock) do
    with true <- open_intake_of?(locked, waitlist_id) || {:error, :concurrent_change},
         {:ok, view} <-
           IntakeCommands.intake_command_locked(locked, :refund_carried_fee, context, clock) do
      {:ok, fee_command_view(waitlist_id, view, view.outcome)}
    end
  end

  # No open Intake: `CarriedFeePolicy.check(:refund, _)` over the person's
  # live fee, else their latest (already done once it was refunded).
  defp refund_fee_alone(%{waitlist_entry: nil}, waitlist_id, _context, _clock) do
    if peek_open_intake(waitlist_id) == nil,
      do: {:error, :person_not_found},
      else: {:error, :concurrent_change}
  end

  defp refund_fee_alone(%{waitlist_entry: entry, carried_fee: nil}, waitlist_id, _context, clock) do
    case CarriedFeePolicy.check(
           :refund,
           person_fee_facts(entry, latest_fee(waitlist_id), Clock.read(clock))
         ) do
      :already_done -> {:ok, fee_command_view(waitlist_id, nil, :already_done)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refund_fee_alone(%{waitlist_entry: entry, carried_fee: fee}, waitlist_id, context, clock) do
    reading = Clock.read(clock)

    with true <- peek_open_intake(waitlist_id) == nil || {:error, :concurrent_change},
         :ok <- CarriedFeePolicy.check(:refund, person_fee_facts(entry, fee, reading)),
         {:ok, _settled} <-
           Settlement.run(
             {:refund_carried_fee, :no_intake},
             %{waitlist_entry: entry, carried_fee: fee},
             reading,
             actor: context.actor
           ) do
      {:ok, fee_command_view(waitlist_id, nil, :done)}
    end
  end

  defp fee_command_view(waitlist_id, intake_view, outcome) do
    fee =
      Repo.one(
        from(f in CarriedFee,
          where: f.waitlist_id == ^waitlist_id,
          order_by: [desc: f.status_changed_at, desc: f.created_at],
          limit: 1
        )
      )

    %{
      waitlist_id: waitlist_id,
      carried_fee: fee && Map.take(fee, [:id, :status]),
      intake: intake_view,
      outcome: outcome
    }
  end

  # `link_carried_fee_payment`: an imported Carried Fee (no payment this
  # system made) linked to the Stripe payment the person originally paid
  # with, by PaymentIntent id. Stripe is read between transactions — the
  # amount is what Stripe says the payment took, never typed in — and the
  # link written under the person's entry → Carried Fee locks after a
  # re-read. Once linked the fee refunds through Stripe like a deferral's.
  defp link_fee_payment(waitlist_id, attrs, clock) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id),
         {:ok, payment_intent_id} <- payment_intent_reference(attrs),
         {:ok, peek} <- peek_linkable_fee(waitlist_id, payment_intent_id) do
      link_peeked_fee(peek, waitlist_id, payment_intent_id, clock)
    end
  end

  defp link_peeked_fee({:linked, fee}, _waitlist_id, _id, _clock),
    do: {:ok, linked_fee_view(fee, :already_done)}

  defp link_peeked_fee({:link, _fee}, waitlist_id, payment_intent_id, clock) do
    with {:ok, payment} <- IntakeRefunds.original_payment(payment_intent_id) do
      transact(fn ->
        with_locked(
          %{
            waitlist_entry: required(from(e in WaitlistEntry, where: e.id == ^waitlist_id)),
            carried_fee: live_fee_query(waitlist_id)
          },
          &link_fee_locked(&1, payment_intent_id, payment, clock)
        )
      end)
    end
  end

  defp payment_intent_reference(attrs) do
    case fetch_attr(attrs, :payment_intent_id) do
      id when is_binary(id) ->
        id = String.trim(id)

        if Regex.match?(~r/\Api_[A-Za-z0-9_-]{1,250}\z/, id),
          do: {:ok, id},
          else: {:error, :invalid_payment_reference}

      _missing ->
        {:error, :invalid_payment_reference}
    end
  end

  defp peek_linkable_fee(waitlist_id, payment_intent_id) do
    case Repo.one(live_fee_query(waitlist_id)) do
      nil -> {:error, :no_carried_fee}
      fee -> linkable(fee, payment_intent_id)
    end
  end

  # `CarriedFeePolicy.check(:link_payment, _)`; asking again for the
  # PaymentIntent already linked is already done.
  defp linkable(%CarriedFee{} = fee, payment_intent_id) do
    facts = CarriedFeePolicy.facts(fee: fee, refund: fee_refund(fee), entry: nil, now: nil)

    case CarriedFeePolicy.check(:link_payment, facts) do
      :ok ->
        if Repo.exists?(
             from(p in IntakePayment, where: p.stripe_payment_intent_id == ^payment_intent_id)
           ),
           do: {:error, :payment_already_linked},
           else: {:ok, {:link, fee}}

      {:error, :already_linked} when fee.stripe_payment_intent_id == payment_intent_id ->
        {:ok, {:linked, fee}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_fee_locked(%{carried_fee: nil}, _id, _payment, _clock), do: {:error, :no_carried_fee}

  defp link_fee_locked(%{carried_fee: fee}, payment_intent_id, payment, _clock) do
    case linkable(fee, payment_intent_id) do
      {:ok, {:linked, fee}} ->
        {:ok, linked_fee_view(fee, :already_done)}

      {:ok, {:link, fee}} ->
        with {:ok, fee} <-
               fee
               |> CarriedFee.link_changeset(payment_intent_id, payment.amount, payment.currency)
               |> persist(),
             do: {:ok, linked_fee_view(fee, :done)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp linked_fee_view(%CarriedFee{} = fee, outcome) do
    fee
    |> Map.take([:id, :waitlist_id, :status, :amount_cents, :currency, :stripe_payment_intent_id])
    |> Map.put(:outcome, outcome)
  end

  @doc false
  # ALE-402 parity seam: the `CarriedFeePolicy` facts of the person's live
  # Carried Fee, else their latest, under the entry → Carried Fee locks the
  # Waitlist tab's commands take. Nothing is written.
  @spec locked_carried_fee_facts(binary(), Clock.t()) ::
          {:ok, CarriedFeePolicy.t()} | {:error, term()}
  def locked_carried_fee_facts(waitlist_id, %Clock{} = clock) do
    with {:ok, waitlist_id} <- cast_person_id(waitlist_id) do
      read_locked(
        %{
          waitlist_entry: from(e in WaitlistEntry, where: e.id == ^waitlist_id),
          carried_fee: live_fee_query(waitlist_id)
        },
        fn %{waitlist_entry: entry, carried_fee: fee} ->
          person_fee_facts(entry, fee || latest_fee(waitlist_id), Clock.read(clock))
        end
      )
    end
  end

  # The person's fee as `CarriedFeePolicy` judges it, with its latest
  # refund, under the person's entry lock.
  defp person_fee_facts(entry, fee, reading),
    do: CarriedFeePolicy.facts(fee: fee, refund: fee_refund(fee), entry: entry, now: reading.now)
end
