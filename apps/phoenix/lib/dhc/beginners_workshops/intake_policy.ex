defmodule Dhc.BeginnersWorkshops.IntakePolicy do
  @moduledoc """
  Pure rules for the console's Intake commands (ALE-386), shared by the
  boundary (`Dhc.BeginnersWorkshops.Commands`, deciding under the lock) and
  the console read model (`WorkshopConsole`, advising without one) — the
  `Dhc.Inventory.LoanPolicy` precedent. Nothing here reads the database or
  the clock. Both adapters build the facts with `facts/1` (ALE-402); the
  Carried Fee half of the rule is `CarriedFeePolicy`, which
  `refund_carried_fee` delegates to.

  `check/2` is the one rule per command:

    * `:ok` — the command would act now;
    * `:already_done` — the Intake is already where the command leads, so
      repeating it succeeds and does nothing again;
    * `{:error, reason}` — refused with a named reason.

  `available_commands/1` is exactly the commands whose `check/2` is `:ok`,
  so what the console offers can be stale but never *different* from what
  the boundary decides. A later Intake command joins `@commands` and gets a
  `check/2` clause here.
  """

  alias Dhc.BeginnersWorkshops.{CarriedFee, CarriedFeePolicy}

  @type command ::
          :decline
          | :defer
          | :confirm
          | :cancel_with_refund
          | :withdraw
          | :refund_carried_fee
          | :resend_link
          | :rotate_link
          | :correct_attendance
  @type decision :: :ok | :already_done | {:error, atom()}

  @typedoc """
  The facts the rule reads — closed (`@enforce_keys`) and built only by
  `facts/1`, from the raw rows both adapters have (the boundary's locked
  rows, the console's roster row):

    * `state` / `paid_via` — the Intake's (`state: nil`: the person has no
      open Intake, the Waitlist tab's Withdraw);
    * `standing` — the person's Waitlist status, else (ALE-396) an
      anonymised attendee's `invitation_outcome` when it is `invited` or
      `joined`, else `nil`;
    * `carried_fee` — the person's live Carried Fee as `CarriedFeePolicy`
      facts, or `nil`; `latest_fee_refunded` — with no live fee, whether
      their latest one was refunded;
    * `workshop_status`, and `correction` — the state a
      `correct_attendance` asks for (`nil` when the console asks whether any
      correction is possible).

  A boundary command's facts hold only the rows it locks; each `check/2`
  clause reads only what its command locks.
  """
  @type t :: %__MODULE__{
          state: String.t() | nil,
          paid_via: String.t() | nil,
          standing: String.t() | nil,
          carried_fee: CarriedFeePolicy.t() | nil,
          latest_fee_refunded: boolean(),
          workshop_status: String.t() | nil,
          correction: String.t() | nil
        }
  @type facts :: t()

  @enforce_keys [
    :state,
    :paid_via,
    :standing,
    :carried_fee,
    :latest_fee_refunded,
    :workshop_status,
    :correction
  ]
  defstruct @enforce_keys

  @commands [
    :decline,
    :defer,
    :confirm,
    :cancel_with_refund,
    :withdraw,
    :refund_carried_fee,
    :resend_link,
    :rotate_link,
    :correct_attendance
  ]
  @open_states ~w(contacted paid)

  # ALE-393: the attendance corrections, from → the states it may become.
  @corrections %{"attended" => ~w(no_show), "no_show" => ~w(attended deferred)}
  @correction_states ~w(attended no_show deferred)

  @doc "Every console Intake command, in display order."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc """
  The facts, from raw values; every key is required:

    * `intake:` — the Intake (or a row with its `state`, `paid_via` and
      `invitation_outcome`), or `nil` when the person has no open Intake;
    * `entry:` — the person's Waitlist entry (or a row with its `status`
      and `removed_at`), or `nil` once anonymised (or not locked);
    * `carried_fee:` — the person's live Carried Fee (or a row with what
      `CarriedFeePolicy.facts/1` reads), or `nil`; `carried_fee_refund:` —
      that fee's latest refund as `%{status: _, followed_up: _}`, or `nil`;
    * `latest_fee_refunded:` — with no live fee, whether the person's
      latest Carried Fee was refunded;
    * `workshop_status:`, `correction:` and `now:`.
  """
  @spec facts(keyword()) :: t()
  def facts(opts) do
    intake = Keyword.fetch!(opts, :intake)
    entry = Keyword.fetch!(opts, :entry)
    fee = Keyword.fetch!(opts, :carried_fee)
    refund = Keyword.fetch!(opts, :carried_fee_refund)
    now = Keyword.fetch!(opts, :now)

    %__MODULE__{
      state: intake && intake.state,
      paid_via: intake && intake.paid_via,
      standing: standing(entry, intake),
      carried_fee: live_fee(fee, refund, entry, now),
      latest_fee_refunded: Keyword.fetch!(opts, :latest_fee_refunded),
      workshop_status: Keyword.fetch!(opts, :workshop_status),
      correction: Keyword.fetch!(opts, :correction)
    }
  end

  defp standing(%{status: status}, _intake), do: status

  # ALE-396: an anonymised attendee keeps what became of them.
  defp standing(nil, %{invitation_outcome: outcome}) when outcome in ~w(invited joined),
    do: outcome

  defp standing(nil, _intake), do: nil

  defp live_fee(nil, _refund, _entry, _now), do: nil

  defp live_fee(%{status: status} = fee, refund, entry, now) do
    unless status in CarriedFee.live_statuses(),
      do: raise(ArgumentError, "IntakePolicy.facts/1 takes the live Carried Fee, got #{status}")

    CarriedFeePolicy.facts(fee: fee, refund: refund, entry: entry, now: now)
  end

  @doc """
  Whether `command` may run on an Intake in its current `state`:

    * `decline` — a `contacted` Intake becomes `declined`; a `declined` one
      is already there; a `paid` one is `:already_paid` (defer, cancel with
      refund or withdraw instead); every other state is `:intake_closed`;
    * `defer` (ALE-388) — a `paid` Intake becomes `deferred`; a `deferred`
      one is already there; a `contacted` one is `:intake_not_paid` (decline
      instead); every other state is `:intake_closed`;
    * `confirm` (ALE-388) — a `contacted` Intake whose person holds a `held`
      Carried Fee becomes `paid`; without one it is `:no_carried_fee`; an
      Intake already paid by confirmation is already there, one paid through
      Stripe is `:already_paid`; every other state is `:intake_closed`.
      Seats (`:full`) are judged by the boundary under the lock;
    * `cancel_with_refund` (ALE-387) — a `paid` Intake becomes
      `cancelled_refunded`, refunding the Stripe payment or (ALE-389) the
      Carried Fee that paid it; a `cancelled_refunded` one is already there;
      a `contacted` one is `:intake_not_paid` (decline or withdraw instead);
      every other state is `:intake_closed`;
    * `withdraw` (ALE-387) — a `contacted` Intake becomes `declined` and a
      `paid` one `withdrawn`; a `withdrawn` one is already there, and so is
      a `declined` one whose person is already `removed` with no held
      Carried Fee left to settle (what a withdrawal of a contacted Intake
      leaves). A `declined` Intake of someone still waiting was declined,
      not withdrawn, and like every other state is `:intake_closed`.
      With no open Intake (`state: nil`, the Waitlist tab, ALE-402) the
      person is removed; that is already done when they are `removed` and
      hold no live Carried Fee, and (ALE-417) refused as `:already_invited`
      once they are `invited` or `joined` (the Settlement's withdrawal
      rule). Whether the refund choice was given
      (`refund_choice_required?/1`) is the command's own input, not the
      Intake's state, so the boundary checks it;
    * `refund_carried_fee` (ALE-389) — the person's `held` Carried Fee is
      refunded (`CarriedFeePolicy.check(:refund, _)`); the Intake itself
      does not move (a `contacted` one stays contacted and asks for
      payment). A `paid` Intake is `:already_paid` (cancel with refund or
      withdraw instead); a live fee `applied` elsewhere is
      `:no_carried_fee`; with no live fee it is already there when the
      person's latest fee was refunded, and `:no_carried_fee` otherwise;
    * `resend_link` / `rotate_link` — open Intakes only (`:intake_closed`).
      They have no target state, so each run sends again;
    * `correct_attendance` (ALE-393) — after Attendance Finalisation only
      (`:before_finalisation`; a cancelled workshop is `:already_cancelled`):
      `attended → no_show`, `no_show → attended | deferred`. An Intake
      already in the asked state is already there; once the person's
      standing is `invited` or `joined` it is `:already_invited` (membership
      never rests on a changed record); any other move is
      `:not_correctable`. Without a `correction` it answers whether any
      correction is possible (the console's question).

  A plain map is read as `legacy_facts/1` reads it.
  """
  @spec check(command(), t() | map()) :: decision()
  def check(command, %__MODULE__{} = facts), do: decide(command, facts)
  def check(command, %{state: _} = partial), do: decide(command, legacy_facts(partial))

  defp decide(:decline, %{state: "contacted"}), do: :ok
  defp decide(:decline, %{state: "declined"}), do: :already_done
  defp decide(:decline, %{state: "paid"}), do: {:error, :already_paid}
  defp decide(:decline, %{state: _closed}), do: {:error, :intake_closed}

  defp decide(:defer, %{state: "paid"}), do: :ok
  defp decide(:defer, %{state: "deferred"}), do: :already_done
  defp decide(:defer, %{state: "contacted"}), do: {:error, :intake_not_paid}
  defp decide(:defer, %{state: _closed}), do: {:error, :intake_closed}

  defp decide(:confirm, %{state: "contacted"} = facts),
    do: if(live_status(facts) == "held", do: :ok, else: {:error, :no_carried_fee})

  defp decide(:confirm, %{state: "paid", paid_via: "carried_fee"}), do: :already_done
  defp decide(:confirm, %{state: "paid"}), do: {:error, :already_paid}
  defp decide(:confirm, %{state: _closed}), do: {:error, :intake_closed}

  defp decide(:cancel_with_refund, %{state: "paid"}), do: :ok
  defp decide(:cancel_with_refund, %{state: "cancelled_refunded"}), do: :already_done
  defp decide(:cancel_with_refund, %{state: "contacted"}), do: {:error, :intake_not_paid}
  defp decide(:cancel_with_refund, %{state: _closed}), do: {:error, :intake_closed}

  defp decide(:withdraw, %{state: nil, standing: "removed", carried_fee: nil}), do: :already_done

  defp decide(:withdraw, %{state: nil, standing: standing}) when standing in ~w(invited joined),
    do: {:error, :already_invited}

  defp decide(:withdraw, %{state: nil}), do: :ok
  defp decide(:withdraw, %{state: "contacted"}), do: :ok
  defp decide(:withdraw, %{state: "paid"}), do: :ok
  defp decide(:withdraw, %{state: "withdrawn"}), do: :already_done

  defp decide(:withdraw, %{state: "declined"} = facts) do
    if facts.standing == "removed" and live_status(facts) != "held",
      do: :already_done,
      else: {:error, :intake_closed}
  end

  defp decide(:withdraw, %{state: _closed}), do: {:error, :intake_closed}

  defp decide(:refund_carried_fee, %{state: "paid"}), do: {:error, :already_paid}

  defp decide(:refund_carried_fee, %{carried_fee: nil, latest_fee_refunded: true}),
    do: :already_done

  defp decide(:refund_carried_fee, %{carried_fee: nil}), do: {:error, :no_carried_fee}

  defp decide(:refund_carried_fee, %{carried_fee: %CarriedFeePolicy{status: "applied"}}),
    do: {:error, :no_carried_fee}

  defp decide(:refund_carried_fee, %{carried_fee: fee}), do: CarriedFeePolicy.check(:refund, fee)

  defp decide(command, %{state: state}) when command in [:resend_link, :rotate_link],
    do: if(state in @open_states, do: :ok, else: {:error, :intake_closed})

  defp decide(:correct_attendance, facts) do
    case facts.workshop_status do
      "finalised" -> check_correction(facts, facts.correction)
      "cancelled" -> {:error, :already_cancelled}
      _scheduled -> {:error, :before_finalisation}
    end
  end

  defp live_status(%{carried_fee: nil}), do: nil
  defp live_status(%{carried_fee: %CarriedFeePolicy{status: status}}), do: status

  @doc """
  ALE-393: the states `correct_attendance` would move this Intake to now, in
  display order — each one `check/2` allows.
  """
  @spec attendance_corrections(t()) :: [String.t()]
  def attendance_corrections(%__MODULE__{} = facts) do
    facts.state
    |> then(&Map.get(@corrections, &1, []))
    |> Enum.filter(&(check(:correct_attendance, %{facts | correction: &1}) == :ok))
  end

  @doc "The states an attendance correction may name."
  @spec correction_states() :: [String.t()]
  def correction_states, do: @correction_states

  # After finalisation: where the Intake already is, then the standing, then
  # the table.
  defp check_correction(%{state: state}, state), do: :already_done

  defp check_correction(facts, correction) do
    targets = Map.get(@corrections, facts.state, [])

    cond do
      facts.standing in ~w(invited joined) -> {:error, :already_invited}
      correction == nil and targets != [] -> :ok
      correction in targets -> :ok
      true -> {:error, :not_correctable}
    end
  end

  @doc """
  ALE-387/389: whether `withdraw` needs the refund-or-forfeit choice
  (`:refund_choice_required` without it) — whenever there is money to
  settle: a `paid` Intake (its payment or the Carried Fee that paid it), or
  a `contacted` Intake, or no open Intake (the Waitlist tab), whose person
  holds a live Carried Fee. The boundary asks it under the lock and the
  console row says so (`refund_choice`), so the Withdraw dialog asks
  exactly when Phoenix requires it.
  """
  @spec refund_choice_required?(t()) :: boolean()
  def refund_choice_required?(%__MODULE__{state: "paid"}), do: true

  def refund_choice_required?(%__MODULE__{state: state, carried_fee: fee})
      when state in [nil, "contacted"],
      do: fee != nil

  def refund_choice_required?(%__MODULE__{}), do: false

  @doc """
  The commands the console offers for an Intake: those `check/2` allows now.
  A plain map is read as `legacy_facts/1` reads it.
  """
  @spec available_commands(t() | map()) :: [command()]
  def available_commands(%__MODULE__{} = facts),
    do: Enum.filter(@commands, &(decide(&1, facts) == :ok))

  def available_commands(%{state: _} = partial), do: available_commands(legacy_facts(partial))

  # The pre-ALE-402 partial-map shape, kept so the direct table tests of
  # that era still read the same rule: `state` is required; `paid_via`,
  # `standing`, `workshop_status` and `correction` absent are `nil`;
  # `carried_fee` is the live fee's status (absent: none), refundable unless
  # `fee_refundable: false` and taken to be linked; `carried_fee_refunded`
  # absent is false. No adapter uses it: they build `facts/1`.
  @legacy %{
    paid_via: nil,
    standing: nil,
    workshop_status: nil,
    correction: nil,
    carried_fee: nil,
    fee_refundable: true,
    carried_fee_refunded: false
  }

  @doc false
  @spec legacy_facts(map()) :: t()
  def legacy_facts(%{state: state} = partial) do
    given = Map.merge(@legacy, partial)

    %__MODULE__{
      state: state,
      paid_via: given.paid_via,
      standing: given.standing,
      carried_fee: legacy_fee(given.carried_fee, given.fee_refundable),
      latest_fee_refunded: given.carried_fee_refunded,
      workshop_status: given.workshop_status,
      correction: given.correction
    }
  end

  defp legacy_fee(nil, _refundable), do: nil

  defp legacy_fee(status, refundable) do
    %CarriedFeePolicy{
      status: status,
      origin: nil,
      linked: true,
      refund: nil,
      standing: if(refundable, do: "waiting"),
      removed_at: nil,
      now: nil
    }
  end
end
