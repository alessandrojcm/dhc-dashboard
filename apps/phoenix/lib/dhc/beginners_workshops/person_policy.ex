defmodule Dhc.BeginnersWorkshops.PersonPolicy do
  @moduledoc """
  Pure rules for the Waitlist tab's person commands (ALE-417): `withdraw`,
  `delete_person` and `refund_carried_fee` naming a person, shaped like
  `IntakePolicy`. The boundary (`Commands.People`) decides by them under the
  person's locks and the person read (`PeopleView`) advises by the very
  same rule without them. Nothing here reads the database or the clock.

  Every command comes from an existing rule, never re-derived:

    * `withdraw` — `IntakePolicy.check(:withdraw, _)` over the person's open
      Intake, or `state: nil` without one;
    * `refund_carried_fee` — with an open Intake the console's
      `IntakePolicy.check(:refund_carried_fee, _)` (which delegates to
      `CarriedFeePolicy`), else `CarriedFeePolicy.check(:refund, _)`;
    * `delete_person` — `check(:delete_person, _)`, which
      `{:delete_person, …}` calls under its locks: refused with an open
      Intake (`:open_intake`) and when `Dhc.Waitlist.hard_delete/1` would
      refuse (`:not_deletable`: standing `invited`/`joined`, a claimed
      profile, or an Invitation that still names the person).

  `refund_choice_required?/1` says whether an offered Withdraw or Delete
  needs the refund-or-forfeit choice.
  """

  alias Dhc.BeginnersWorkshops.{CarriedFeePolicy, Intake, IntakePolicy}

  @type command :: :withdraw | :delete_person | :refund_carried_fee
  @type decision :: :ok | :already_done | {:error, atom()}

  @typedoc """
  The facts, closed and built only by `facts/1`:

    * `intake` — the person's `IntakePolicy` facts over their open Intake,
      or with `state: nil` without one. The person commands never read the
      workshop, so `workshop_status` and `correction` are `nil`;
    * `carried_fee` — `CarriedFeePolicy` facts of their live Carried Fee,
      else their latest (`status: nil` when they never held one);
    * `deletable` — whether `Dhc.Waitlist.hard_delete/1` would not refuse
      them as `:not_deletable` (`Dhc.Waitlist.deletable_ids/1`).
  """
  @type t :: %__MODULE__{
          intake: IntakePolicy.t(),
          carried_fee: CarriedFeePolicy.t(),
          deletable: boolean()
        }

  @enforce_keys [:intake, :carried_fee, :deletable]
  defstruct @enforce_keys

  @commands [:withdraw, :delete_person, :refund_carried_fee]

  @doc "Every person command, in display order."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc """
  The facts, from raw values; every key is required:

    * `intake:` — the open Intake (or a row with its `state`, `paid_via`
      and `invitation_outcome`), or `nil`;
    * `entry:` — the person's Waitlist entry (or a row with its `status`
      and `removed_at`);
    * `live_fee:` — their live Carried Fee (or a row with what
      `CarriedFeePolicy.facts/1` reads), or `nil`; `latest_fee:` — with no
      live fee, their latest one, or `nil`;
    * `fee_refund:` — the latest refund of the live fee, else of the latest
      fee, as `%{status: _, followed_up: _}`, or `nil`;
    * `deletable:` and `now:`.
  """
  @spec facts(keyword()) :: t()
  def facts(opts) do
    entry = Keyword.fetch!(opts, :entry)
    live = Keyword.fetch!(opts, :live_fee)
    latest = Keyword.fetch!(opts, :latest_fee)
    refund = Keyword.fetch!(opts, :fee_refund)
    now = Keyword.fetch!(opts, :now)

    %__MODULE__{
      intake:
        IntakePolicy.facts(
          intake: Keyword.fetch!(opts, :intake),
          entry: entry,
          carried_fee: live,
          carried_fee_refund: live && refund,
          latest_fee_refunded: live == nil and match?(%{status: "refunded"}, latest),
          workshop_status: nil,
          correction: nil,
          now: now
        ),
      carried_fee:
        CarriedFeePolicy.facts(fee: live || latest, refund: refund, entry: entry, now: now),
      deletable: Keyword.fetch!(opts, :deletable)
    }
  end

  @doc """
  Whether `command` may run on the person now (see the moduledoc).
  `delete_person` is never already done: a deleted person is not found.
  """
  @spec check(command(), t()) :: decision()
  def check(:withdraw, %__MODULE__{intake: intake}), do: IntakePolicy.check(:withdraw, intake)

  def check(:refund_carried_fee, %__MODULE__{intake: %{state: nil}, carried_fee: fee}),
    do: CarriedFeePolicy.check(:refund, fee)

  def check(:refund_carried_fee, %__MODULE__{intake: intake}),
    do: IntakePolicy.check(:refund_carried_fee, intake)

  def check(:delete_person, %__MODULE__{intake: %{state: state}, deletable: deletable}) do
    cond do
      state in Intake.open_states() -> {:error, :open_intake}
      not deletable -> {:error, :not_deletable}
      true -> :ok
    end
  end

  @doc """
  What the Waitlist tab offers: the commands `check/2` allows now, except
  that while a refund of the person's fee awaits its follow-up the tab
  offers the Carried Fee panel's follow-ups rather than a new refund
  (`CarriedFeePolicy.available/1`'s rule).
  """
  @spec available_commands(t()) :: [command()]
  def available_commands(%__MODULE__{} = facts),
    do: Enum.filter(@commands, &offered?(&1, facts))

  defp offered?(:refund_carried_fee, %__MODULE__{carried_fee: %{refund: :failed}}), do: false

  defp offered?(command, facts), do: check(command, facts) == :ok

  @doc """
  Whether an offered Withdraw or Delete needs the refund-or-forfeit choice:
  Withdraw by `IntakePolicy.refund_choice_required?/1`, Delete whenever the
  person holds a live Carried Fee (the `{:delete_person, :deleted}`
  Settlement row's rule).
  """
  @spec refund_choice_required?(t()) :: boolean()
  def refund_choice_required?(%__MODULE__{intake: intake} = facts) do
    (offered?(:withdraw, facts) and IntakePolicy.refund_choice_required?(intake)) or
      (offered?(:delete_person, facts) and intake.carried_fee != nil)
  end
end
