defmodule Dhc.BeginnersWorkshops.Commands.Settlement do
  @moduledoc """
  A **Settlement** (`CONTEXT.md`, ALE-404): what an Intake's closing, or a
  person leaving the Waitlist, does to that person — their Waitlist Status,
  their Seat Hold, their Carried Fee, any refund, and the Intake Email that
  tells them. Every cause and ending has exactly one row in `@settlements`,
  and `run/4` is the one function that carries a row out.

  `run/4` runs **inside the caller's `with_locked/2`**, against rows the
  caller already holds in lock order (Beginners' Workshop → Waitlist entry
  → Intake → Carried Fee → payment → refund). It opens no transaction and
  takes no lock of its own; every status change goes through
  `Commands.Protocol.transition/3`, every refund row through
  `Commands.insert_refund/4`, every standing change through
  `Dhc.Waitlist.change_standing/3` and every notice through
  `IntakeEmails.deliver/5`. Whether a command may run at all is
  `IntakePolicy` / `CarriedFeePolicy`'s decision, made by the caller before
  it names the row; the caller also keeps its own history row
  (`IntakeEvent`) and anything that is not about the person (a door
  check-in discarded, the Staff list frozen, the workshop's own status).

  Reach lets only `Commands` and `Commands.*` call this module.

  ## A row

  A row is an **ordered** list of steps — the order is the order of the
  writes, and so of the jobs and ledger rows a test can see — plus `from`,
  the states its moves start from (read by the table test, which checks
  every move against `Commands.transitions/0` and `Dhc.Waitlist.Standing`).
  The steps are a closed set:

    * `{:close, state}` — the Intake closes as `state`;
    * `:release_holds` — each live Seat Hold the caller locked becomes
      `releasing` (only Stripe ends the session; a completion that lands
      anyway is refunded by `complete_payment`'s `paid_after_close`);
    * `{:standing, target, rule}` — the Waitlist Status moves to `target`
      when `rule` says it does (an anonymised person has no standing):
      * `:from_removed` — only a removed person moves (back to `waiting`,
        keeping their registration date); a waiting one already is;
      * `:from_waiting` — only a waiting person moves (a lapse); one staff
        already removed stays so;
      * `:withdrawal` — every standing moves except one already `removed`;
        `invited`/`joined` belong to Onboarding and refuse with
        `:already_invited`;
      * `:if_allowed` — moves whenever `Standing` allows it, else stays
        (finalisation: someone a coordinator moved keeps that standing);
      * `:required` — moves unless already there, and a refusal stands
        (a correction must reach its standing);
    * `{:paying_fee, status}` — the Carried Fee that paid a
      Carried-Fee-paid Intake moves to `status` (`:illegal_transition`
      when the locked fee is no longer it); a Stripe-paid Intake has none;
    * `:carry` — the person's money becomes a `held` Carried Fee: the fee
      that paid a Carried-Fee-paid Intake is held again, a Stripe-paid
      Intake's paying payment makes a new deferral fee (`:payment_not_found`
      without one, `:illegal_transition` when the person already holds a
      live fee);
    * `{:refund_payment, reason}` — the payment that paid a Stripe-paid
      Intake is refunded in full (`:nothing_to_refund` when it took
      nothing);
    * `{:refund_fee, selector, reason}` — a Carried Fee is refunded in full
      against its original payment and becomes `refunded`: `:paying`
      selects as `{:paying_fee, _}` does, `:live` the person's locked live
      fee (none: nothing);
    * `{:forfeit_fee, :live}` — the person's locked live fee is forfeited
      (none: nothing);
    * `{:by_choice, refunded, forfeited}` — the person's refund-or-forfeit
      choice picks a branch. The choice is checked before any step runs:
      it is required (`:refund_choice_required`) exactly when there is
      money to settle (`IntakePolicy.refund_choice_required?/1` over the
      caller's facts; with no facts, a live fee), and ignored otherwise;
    * `{:notice, email, occasion}` — the Intake Email, through
      `IntakeEmails.deliver/5`: about the Intake when there is one, else
      about the person, logged on the refund's Intake if any. `occasion`
      names an `IntakeEmails.Occasion` constructor, with `:refund` or `:fee`
      as its argument (`withdrawn` vs `withdrawn:<id>` are different rows);
    * `:follow_up_when_due` — one-off for a late `attended` correction: the
      Follow-up, if `WorkshopPolicy.follow_up_due?/2` says it is owed now.

  A new ending's consequences are a new row here, never new steps in a
  command.
  """

  import Dhc.BeginnersWorkshops.Commands.Protocol, only: [persist: 1, transition: 3]

  alias Dhc.BeginnersWorkshops.{
    CarriedFee,
    Clock,
    Intake,
    IntakeEmails,
    IntakePayment,
    IntakePolicy,
    IntakeRefund,
    WorkshopPolicy
  }

  alias Dhc.BeginnersWorkshops.Commands
  alias Dhc.BeginnersWorkshops.IntakeEmails.Occasion
  alias Dhc.Repo
  alias Dhc.Waitlist
  alias Dhc.Waitlist.{Standing, WaitlistEntry}

  @type key :: {atom(), atom() | String.t()}

  @type rows :: %{
          optional(:workshop) => struct() | nil,
          optional(:waitlist_entry) => WaitlistEntry.t() | nil,
          optional(:intake) => Intake.t() | nil,
          optional(:carried_fee) => CarriedFee.t() | nil,
          optional(:payment) => IntakePayment.t() | nil,
          optional(:holds) => [IntakePayment.t()]
        }

  @type result :: %{
          intake: Intake.t() | nil,
          waitlist_entry: WaitlistEntry.t() | nil,
          carried_fee: CarriedFee.t() | nil,
          refund: IntakeRefund.t() | nil
        }

  # The refund-or-forfeit branches of a withdrawal, about an Intake.
  @withdrawn_about_intake {:by_choice,
                           [
                             {:refund_fee, :live, "withdrawn"},
                             {:notice, "withdrawn_refunded", :withdrawn}
                           ],
                           [
                             {:forfeit_fee, :live},
                             {:notice, "withdrawn_forfeited", :withdrawn}
                           ]}

  @settlements %{
    # ── Attendance Finalisation (ALE-391): the check-in record decides ──
    {:finalisation, :attended} => %{
      from: %{intake: ["paid"], standing: ["waiting", "removed"], carried_fee: ["applied"]},
      steps: [
        {:close, "attended"},
        {:standing, "attended", :if_allowed},
        {:paying_fee, "spent"}
      ]
    },
    # A no-show is removed (story 104) and emailed nothing.
    {:finalisation, :no_show} => %{
      from: %{intake: ["paid"], standing: ["waiting"], carried_fee: ["applied"]},
      steps: [
        {:close, "no_show"},
        {:standing, "removed", :if_allowed},
        {:paying_fee, "forfeited"}
      ]
    },

    # ── A contacted Intake at the Payment Cutoff or at finalisation ─────
    # (`WorkshopPolicy.cutoff_settlement/3` decides which, ALE-385.)
    # A lapse removes a waiting person (story 86).
    {:cutoff, :lapse} => %{
      from: %{intake: ["contacted"], standing: ["waiting"]},
      steps: [{:close, "lapsed"}, {:standing, "removed", :from_waiting}]
    },
    # A return leaves the standing and its priority date alone (story 87).
    {:cutoff, :return} => %{
      from: %{intake: ["contacted"]},
      steps: [{:close, "returned"}]
    },

    # ── correct_attendance (ALE-393) ────────────────────────────────────
    {:correct_attendance, "attended"} => %{
      from: %{intake: ["no_show"], standing: ["removed"], carried_fee: ["forfeited"]},
      steps: [
        {:close, "attended"},
        {:standing, "attended", :required},
        {:paying_fee, "spent"},
        :follow_up_when_due
      ]
    },
    {:correct_attendance, "no_show"} => %{
      from: %{intake: ["attended"], standing: ["attended"], carried_fee: ["spent"]},
      steps: [
        {:close, "no_show"},
        {:standing, "removed", :required},
        {:paying_fee, "forfeited"}
      ]
    },
    {:correct_attendance, "deferred"} => %{
      from: %{intake: ["no_show"], standing: ["removed"], carried_fee: ["forfeited"]},
      steps: [
        {:close, "deferred"},
        {:standing, "waiting", :required},
        :carry,
        {:notice, "deferred", :deferred}
      ]
    },

    # ── defer (ALE-388): the money is kept, the place in the queue too ──
    {:defer, :paid} => %{
      from: %{intake: ["paid"], standing: ["removed"], carried_fee: ["applied"]},
      steps: [
        :carry,
        {:close, "deferred"},
        {:standing, "waiting", :from_removed},
        {:notice, "deferred", :deferred}
      ]
    },

    # ── cancel_workshop (ALE-395) ───────────────────────────────────────
    # A paid person is deferred as `defer` does it, told by
    # "Workshop cancelled – paid" instead of "Deferred".
    {:cancel_workshop, :paid} => %{
      from: %{intake: ["paid"], standing: ["removed"], carried_fee: ["applied"]},
      steps: [
        :carry,
        {:close, "deferred"},
        {:standing, "waiting", :from_removed},
        {:notice, "cancelled_paid", :cancelled}
      ]
    },
    # A paid person whose Waitlist entry was deleted has nobody to carry a
    # fee to: the Intake just closes, and the payment stays on record for a
    # manual refund.
    {:cancel_workshop, :paid_anonymised} => %{
      from: %{intake: ["paid"]},
      steps: [{:close, "deferred"}]
    },
    # An unpaid person never had a seat to lose; a holder keeps their
    # `held` fee.
    {:cancel_workshop, :contacted} => %{
      from: %{intake: ["contacted"], standing: ["removed"], payment: ["open"]},
      steps: [
        {:close, "returned"},
        :release_holds,
        {:standing, "waiting", :from_removed},
        {:notice, "cancelled_unpaid", :cancelled}
      ]
    },

    # ── cancel_with_refund (ALE-387, ALE-389) ───────────────────────────
    # The seat is free at once; the person keeps their priority.
    {:cancel_with_refund, :stripe_paid} => %{
      from: %{intake: ["paid"], standing: ["removed"]},
      steps: [
        {:close, "cancelled_refunded"},
        {:refund_payment, "cancelled_with_refund"},
        {:standing, "waiting", :from_removed},
        {:notice, "cancelled_with_refund", :cancelled_with_refund}
      ]
    },
    {:cancel_with_refund, :carried_fee_paid} => %{
      from: %{intake: ["paid"], standing: ["removed"], carried_fee: ["applied"]},
      steps: [
        {:close, "cancelled_refunded"},
        {:refund_fee, :paying, "cancelled_with_refund"},
        {:standing, "waiting", :from_removed},
        {:notice, "cancelled_with_refund", :cancelled_with_refund}
      ]
    },

    # ── decline (ALE-386) ───────────────────────────────────────────────
    {:decline, :contacted} => %{
      from: %{intake: ["contacted"], standing: ["removed"], payment: ["open"]},
      steps: [
        {:close, "declined"},
        :release_holds,
        {:standing, "waiting", :from_removed},
        {:notice, "declined", :declined}
      ]
    },

    # ── withdraw (ALE-387, ALE-389): the person leaves the Waitlist ─────
    # A contacted Intake closes as `declined`; a person without a Carried
    # Fee is emailed nothing.
    {:withdraw, :contacted} => %{
      from: %{
        intake: ["contacted"],
        standing: ["waiting", "attended"],
        carried_fee: ["held"],
        payment: ["open"]
      },
      steps: [
        {:close, "declined"},
        :release_holds,
        {:standing, "removed", :withdrawal},
        @withdrawn_about_intake
      ]
    },
    # A paid one closes as `withdrawn`, freeing the seat at once; the
    # paying payment and the person's fee are refunded or forfeited
    # together.
    {:withdraw, :stripe_paid} => %{
      from: %{intake: ["paid"], standing: ["waiting", "attended"], carried_fee: ["held"]},
      steps: [
        {:close, "withdrawn"},
        {:standing, "removed", :withdrawal},
        {:by_choice,
         [
           {:refund_payment, "withdrawn"},
           {:refund_fee, :live, "withdrawn"},
           {:notice, "withdrawn_refunded", :withdrawn}
         ],
         [
           {:forfeit_fee, :live},
           {:notice, "withdrawn_forfeited", :withdrawn}
         ]}
      ]
    },
    {:withdraw, :carried_fee_paid} => %{
      from: %{intake: ["paid"], standing: ["waiting", "attended"], carried_fee: ["applied"]},
      steps: [
        {:close, "withdrawn"},
        {:standing, "removed", :withdrawal},
        @withdrawn_about_intake
      ]
    },
    # The Waitlist tab, no open Intake: the notice is about the person,
    # logged on the refunded fee's original Intake, and its occasion names
    # the refund or the fee.
    {:withdraw, :no_intake} => %{
      from: %{standing: ["waiting", "attended"], carried_fee: ["held"]},
      steps: [
        {:standing, "removed", :withdrawal},
        {:by_choice,
         [
           {:refund_fee, :live, "withdrawn"},
           {:notice, "withdrawn_refunded", {:withdrawn, :refund}}
         ],
         [
           {:forfeit_fee, :live},
           {:notice, "withdrawn_forfeited", {:withdrawn, :fee}}
         ]}
      ]
    },

    # ── refund_carried_fee (ALE-389): nothing but the fee moves ─────────
    {:refund_carried_fee, :open_intake} => %{
      from: %{carried_fee: ["held"]},
      steps: [
        {:refund_fee, :live, "carried_fee_refunded"},
        {:notice, "carried_fee_refunded", {:carried_fee_refunded, :refund}}
      ]
    },
    {:refund_carried_fee, :no_intake} => %{
      from: %{carried_fee: ["held"]},
      steps: [
        {:refund_fee, :live, "carried_fee_refunded"},
        {:notice, "carried_fee_refunded", {:carried_fee_refunded, :refund}}
      ]
    },

    # ── Hard delete (ALE-396): emails nobody; the caller then deletes ───
    {:delete_person, :deleted} => %{
      from: %{carried_fee: ["held"]},
      steps: [{:by_choice, [{:refund_fee, :live, "deleted"}], [{:forfeit_fee, :live}]}]
    },
    {:purge_retention, :purged} => %{
      from: %{carried_fee: ["held"]},
      steps: [{:forfeit_fee, :live}]
    }
  }

  @doc false
  # The table, for the table test.
  @spec table() :: %{key() => %{from: map(), steps: list()}}
  def table, do: @settlements

  @doc false
  # The ending of a paid Intake, by what paid it.
  @spec paid_by(Intake.t()) :: :stripe_paid | :carried_fee_paid
  def paid_by(%Intake{paid_via: "carried_fee"}), do: :carried_fee_paid
  def paid_by(%Intake{}), do: :stripe_paid

  @doc false
  # Runs the row `key` against the locked `rows` (see `t:rows/0`; `holds`
  # are the live Seat Holds to release, `payment` the payment that paid a
  # paid Intake). `opts`: `actor:` (who requested a refund, `nil` for the
  # system), `choice:` (the refund-or-forfeit choice, `true | false | nil`)
  # and `facts:` (the `IntakePolicy` facts that say whether it is
  # required).
  @spec run(key(), rows(), Clock.reading(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(key, rows, reading, opts \\ []) do
    %{steps: steps} = Map.fetch!(@settlements, key)

    state = %{
      rows: Map.merge(%{waitlist_entry: nil, intake: nil, carried_fee: nil, payment: nil}, rows),
      refund: nil,
      actor: Keyword.get(opts, :actor),
      reading: reading
    }

    with {:ok, choice} <- choice(steps, state.rows, opts),
         {:ok, state} <- run_steps(steps, Map.put(state, :choice, choice)) do
      {:ok,
       %{
         intake: state.rows.intake,
         waitlist_entry: state.rows.waitlist_entry,
         carried_fee: state.rows.carried_fee,
         refund: state.refund
       }}
    end
  end

  # ── The choice ──────────────────────────────────────────────────

  defp choice(steps, rows, opts) do
    if Enum.any?(steps, &match?({:by_choice, _, _}, &1)) and money_to_settle?(rows, opts) do
      case Keyword.get(opts, :choice) do
        refund when is_boolean(refund) -> {:ok, refund}
        _missing -> {:error, :refund_choice_required}
      end
    else
      {:ok, nil}
    end
  end

  # With an Intake the console's rule (`IntakePolicy`); with none (a
  # deletion) a live Carried Fee is the only money.
  defp money_to_settle?(rows, opts) do
    case Keyword.get(opts, :facts) do
      %IntakePolicy{} = facts -> IntakePolicy.refund_choice_required?(facts)
      nil -> rows.carried_fee != nil
    end
  end

  # ── Steps ───────────────────────────────────────────────────────

  defp run_steps(steps, state) do
    Enum.reduce_while(steps, {:ok, state}, fn step, {:ok, state} ->
      case step(step, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp step({:close, to}, %{rows: %{intake: intake}} = state) do
    with {:ok, intake} <- transition(:intake, intake, Intake.close_changeset(intake, to)),
         do: {:ok, put_row(state, :intake, intake)}
  end

  defp step(:release_holds, state) do
    state.rows
    |> Map.get(:holds, [])
    |> Enum.reduce_while({:ok, state}, fn hold, {:ok, state} ->
      case transition(:payment, hold, Ecto.Changeset.change(hold, status: "releasing")) do
        {:ok, _hold} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp step({:standing, to, rule}, %{rows: %{waitlist_entry: entry}} = state) do
    case standing(entry, to, rule, state.reading.now) do
      {:ok, entry} -> {:ok, put_row(state, :waitlist_entry, entry)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp step({:paying_fee, status}, %{rows: rows} = state) do
    case paying_fee(rows) do
      {:ok, nil} ->
        {:ok, state}

      {:ok, fee} ->
        applied_intake_id = if status == "held", do: nil, else: rows.intake.id

        with {:ok, fee} <-
               transition(
                 :carried_fee,
                 fee,
                 CarriedFee.status_changeset(fee, status, applied_intake_id, state.reading.now)
               ),
             do: {:ok, put_row(state, :carried_fee, fee)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp step(:carry, %{rows: %{intake: %Intake{paid_via: "carried_fee"}}} = state),
    do: step({:paying_fee, "held"}, state)

  defp step(:carry, %{rows: %{intake: %Intake{paid_via: "stripe"} = intake} = rows} = state) do
    case rows do
      %{carried_fee: nil, payment: nil} ->
        {:error, :payment_not_found}

      %{carried_fee: nil, payment: payment} ->
        with {:ok, fee} <-
               %{
                 waitlist_id: intake.waitlist_id,
                 payment_id: payment.id,
                 amount_cents: payment.amount_received_cents || payment.amount_cents,
                 currency: payment.currency_received || payment.currency,
                 status_changed_at: state.reading.now
               }
               |> CarriedFee.deferral_changeset()
               |> persist(),
             do: {:ok, put_row(state, :carried_fee, fee)}

      # A Stripe payer who somehow already holds a live fee.
      _holder ->
        {:error, :illegal_transition}
    end
  end

  defp step(:carry, _state), do: {:error, :illegal_transition}

  defp step({:refund_payment, reason}, %{rows: %{intake: %Intake{paid_via: "stripe"}}} = state) do
    case state.rows.payment &&
           Commands.insert_refund(state.rows.payment, reason, state.actor, state.reading) do
      {:ok, %IntakeRefund{} = refund} -> {:ok, add_refund(state, refund)}
      {:error, reason} -> {:error, reason}
      _nothing_taken -> {:error, :nothing_to_refund}
    end
  end

  defp step({:refund_payment, _reason}, state), do: {:ok, state}

  defp step({:refund_fee, selector, reason}, state) do
    with {:ok, fee} <- select_fee(selector, state.rows),
         {:ok, refund, fee} <- refund_fee(fee, state, reason) do
      {:ok, state |> put_row(:carried_fee, fee) |> add_refund(refund)}
    end
  end

  defp step({:forfeit_fee, :live}, %{rows: %{carried_fee: nil}} = state), do: {:ok, state}

  defp step({:forfeit_fee, :live}, %{rows: %{carried_fee: fee}} = state) do
    with {:ok, fee} <-
           transition(
             :carried_fee,
             fee,
             CarriedFee.status_changeset(
               fee,
               "forfeited",
               fee.applied_intake_id,
               state.reading.now
             )
           ),
         do: {:ok, put_row(state, :carried_fee, fee)}
  end

  defp step({:by_choice, _refunded, _forfeited}, %{choice: nil} = state), do: {:ok, state}

  defp step({:by_choice, refunded, _forfeited}, %{choice: true} = state),
    do: run_steps(refunded, state)

  defp step({:by_choice, _refunded, forfeited}, %{choice: false} = state),
    do: run_steps(forfeited, state)

  defp step({:notice, email, occasion}, state) do
    opts = if state.refund, do: [refund: state.refund], else: []

    state
    |> about()
    |> IntakeEmails.deliver(email, occasion(occasion, state), state.reading, opts)
    |> delivered(state)
  end

  defp step(:follow_up_when_due, %{rows: %{workshop: workshop}} = state) do
    if WorkshopPolicy.follow_up_due?(workshop, state.reading) do
      {:intake, state.rows.intake, workshop}
      |> IntakeEmails.deliver("follow_up", Occasion.follow_up(), state.reading)
      |> delivered(state)
    else
      {:ok, state}
    end
  end

  # ── Standing ────────────────────────────────────────────────────

  defp standing(nil, _to, _rule, _now), do: {:ok, nil}

  defp standing(%WaitlistEntry{status: "removed"} = entry, to, :from_removed, now),
    do: Waitlist.change_standing(entry.id, to, now: now)

  defp standing(%WaitlistEntry{} = entry, _to, :from_removed, _now), do: {:ok, entry}

  defp standing(%WaitlistEntry{status: "waiting"} = entry, to, :from_waiting, now),
    do: Waitlist.change_standing(entry.id, to, now: now)

  defp standing(%WaitlistEntry{} = entry, _to, :from_waiting, _now), do: {:ok, entry}

  defp standing(%WaitlistEntry{status: "removed"} = entry, _to, :withdrawal, _now),
    do: {:ok, entry}

  defp standing(%WaitlistEntry{status: status}, _to, :withdrawal, _now)
       when status in ~w(invited joined),
       do: {:error, :already_invited}

  defp standing(%WaitlistEntry{} = entry, to, :withdrawal, now),
    do: Waitlist.change_standing(entry.id, to, now: now)

  defp standing(%WaitlistEntry{status: from} = entry, to, :if_allowed, now) do
    if Standing.allowed?(from, to),
      do: Waitlist.change_standing(entry.id, to, now: now),
      else: {:ok, entry}
  end

  defp standing(%WaitlistEntry{status: to} = entry, to, :required, _now), do: {:ok, entry}

  defp standing(%WaitlistEntry{} = entry, to, :required, now),
    do: Waitlist.change_standing(entry.id, to, now: now)

  # ── Carried Fee ─────────────────────────────────────────────────

  # The fee that paid a Carried-Fee-paid Intake must be the locked one.
  defp paying_fee(%{intake: %Intake{paid_via: "carried_fee", carried_fee_id: id}} = rows) do
    case rows.carried_fee do
      %CarriedFee{id: ^id} = fee -> {:ok, fee}
      _moved_on -> {:error, :illegal_transition}
    end
  end

  defp paying_fee(_stripe_paid), do: {:ok, nil}

  defp select_fee(:paying, rows), do: paying_fee(rows)
  defp select_fee(:live, rows), do: {:ok, rows.carried_fee}

  # The refund row (the one `insert_refund/4`, against the fee's original
  # payment, recorded on the Intake the refund is about) and the fee
  # `refunded`: the obligation is recorded, so the fee is no longer held.
  # A failed refund holds it again (`Commands.hold_fee_again/3`).
  defp refund_fee(nil, _state, _reason), do: {:ok, nil, nil}

  defp refund_fee(%CarriedFee{status: status} = fee, state, reason)
       when status in ["held", "applied"] do
    source = {:carried_fee, fee, original_payment(fee), state.rows.intake}

    with {:ok, refund} <- Commands.insert_refund(source, reason, state.actor, state.reading),
         {:ok, fee} <-
           transition(
             :carried_fee,
             fee,
             CarriedFee.status_changeset(
               fee,
               "refunded",
               fee.applied_intake_id,
               state.reading.now
             )
           ) do
      {:ok, refund, fee}
    end
  end

  defp refund_fee(%CarriedFee{}, _state, _reason), do: {:error, :carried_fee_not_held}

  # A deferral's fee points at its Intake payment row, which is never
  # edited, so it is read without a lock.
  defp original_payment(%CarriedFee{payment_id: nil}), do: nil
  defp original_payment(%CarriedFee{payment_id: id}), do: Repo.get!(IntakePayment, id)

  # ── Notices ─────────────────────────────────────────────────────

  defp about(%{rows: %{intake: %Intake{} = intake, workshop: workshop}}),
    do: {:intake, intake, workshop}

  defp about(%{rows: %{waitlist_entry: entry}, refund: refund}),
    do: {:person, entry, refund && refund.intake_id}

  defp occasion(:declined, _state), do: Occasion.declined()
  defp occasion(:deferred, _state), do: Occasion.deferred()
  defp occasion(:cancelled, _state), do: Occasion.cancelled()
  defp occasion(:cancelled_with_refund, _state), do: Occasion.cancelled_with_refund()
  defp occasion(:withdrawn, _state), do: Occasion.withdrawn()
  defp occasion({:withdrawn, :refund}, state), do: Occasion.withdrawn(state.refund.id)
  defp occasion({:withdrawn, :fee}, state), do: Occasion.withdrawn(state.rows.carried_fee.id)

  defp occasion({:carried_fee_refunded, :refund}, state),
    do: Occasion.carried_fee_refunded(state.refund.id)

  # Queued, already sent and nobody to send to all go on.
  defp delivered({:ok, _queued_or_not}, state), do: {:ok, state}
  defp delivered({:error, reason}, _state), do: {:error, reason}

  # ── State ───────────────────────────────────────────────────────

  defp put_row(state, level, row), do: %{state | rows: Map.put(state.rows, level, row)}

  # The notice names the first refund (a withdrawal refunds the payment
  # before the fee).
  defp add_refund(state, nil), do: state
  defp add_refund(%{refund: nil} = state, refund), do: %{state | refund: refund}
  defp add_refund(state, _later), do: state
end
