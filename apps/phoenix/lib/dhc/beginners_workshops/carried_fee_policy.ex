defmodule Dhc.BeginnersWorkshops.CarriedFeePolicy do
  @moduledoc """
  Pure rules for what may be done with one person's Carried Fee (ALE-389,
  ALE-402), shaped like `IntakePolicy`: the boundary decides by them under
  the person's entry → Carried Fee locks, and the read models
  (`CarriedFeeView`, and `WorkshopConsole` through `IntakePolicy`) advise by
  the very same rule without one. Nothing here reads the database or the
  clock: the facts carry `now`.

  The struct is the facts, closed (`@enforce_keys`) and built only by
  `facts/1` from the raw rows every adapter has:

    * `status` / `origin` — the fee's (`status: nil`: the person never held
      one);
    * `linked` — whether it has a payment a Stripe refund can be made
      against (`CarriedFee.refundable_through_stripe?/1`);
    * `refund` — the refund in question: for a read model and a refund the
      fee's latest, for a follow-up the one followed up. `nil` (none),
      `:not_failed`, `:failed` (awaiting Retry or Record manual refund) or
      `:followed_up` (a follow-up row exists, or a later refund of the same
      fee superseded it);
    * `standing` / `removed_at` — the person's Waitlist entry (`nil` once
      anonymised), which `fee_refundable?/3` reads at `now`.

  `check/2` is one rule per command, `:ok | :already_done | {:error,
  reason}`; `available/1` is what the Waitlist tab offers.
  """

  alias Dhc.BeginnersWorkshops.CarriedFee

  @type command :: :refund | :link_payment | :retry | :manual | :forfeit
  @type refund :: nil | :not_failed | :failed | :followed_up
  @type t :: %__MODULE__{
          status: String.t() | nil,
          origin: String.t() | nil,
          linked: boolean(),
          refund: refund(),
          standing: String.t() | nil,
          removed_at: DateTime.t() | nil,
          now: DateTime.t()
        }
  @type decision :: :ok | :already_done | {:error, atom()}

  @enforce_keys [:status, :origin, :linked, :refund, :standing, :removed_at, :now]
  defstruct @enforce_keys

  @commands [:refund, :link_payment, :retry, :manual, :forfeit]
  @follow_ups [:retry, :manual, :forfeit]

  @doc """
  The facts, from raw values; every key is required:

    * `fee:` — the Carried Fee (or a row with its `status`, `origin`,
      `payment_id`, `stripe_payment_intent_id` and `amount_cents`), or `nil`;
    * `refund:` — `%{status: refund_status, followed_up: boolean}` for the
      refund in question, or `nil`;
    * `entry:` — the person's Waitlist entry (or a row with its `status` and
      `removed_at`), or `nil` once anonymised (or not locked);
    * `now:` — the instant the rule judges retention at.
  """
  @spec facts(keyword()) :: t()
  def facts(opts) do
    fee = Keyword.fetch!(opts, :fee)
    entry = Keyword.fetch!(opts, :entry)

    %__MODULE__{
      status: fee && fee.status,
      origin: fee && fee.origin,
      linked: fee != nil and CarriedFee.refundable_through_stripe?(fee),
      refund: refund_state(Keyword.fetch!(opts, :refund)),
      standing: entry && entry.status,
      removed_at: entry && entry.removed_at,
      now: Keyword.fetch!(opts, :now)
    }
  end

  defp refund_state(nil), do: nil
  defp refund_state(%{status: "failed", followed_up: true}), do: :followed_up
  defp refund_state(%{status: "failed", followed_up: false}), do: :failed
  defp refund_state(%{status: _not_failed}), do: :not_failed

  @doc "Every Carried Fee command, in display order."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc """
  The follow-ups to a failed refund, in display order: what the console's
  Needs attention offers (`WorkshopConsole`, ALE-421) by `check/2`.
  """
  @spec follow_ups() :: [command()]
  def follow_ups, do: @follow_ups

  @doc """
  Whether `command` may run on the fee now:

    * `refund` — a `held` fee of someone who may still have it refunded
      (`fee_refundable?/3`), with a payment to refund against
      (`:payment_not_linked`). A `refunded` fee is already there; with no
      live fee it is `:no_carried_fee`; an `applied` one
      `:carried_fee_applied` (judged after `:fee_not_refundable`);
    * `link_payment` — a live imported fee with no Stripe payment yet:
      `:no_carried_fee` without a live fee, `:not_imported` for a
      deferral's, `:already_linked` once linked (the boundary answers
      `:already_done` itself when the PaymentIntent asked is the linked
      one);
    * `retry` / `manual` / `forfeit` — the refund in question failed
      (`:refund_not_failed`) and has not been followed up
      (`:refund_followed_up`). A refund with no Carried Fee is followed up
      freely, except `forfeit` (`:not_a_carried_fee_refund`). The fee must
      still be owed back: `held`, or (not for `forfeit`) still `refunded`
      because the person has since paid or holds another fee;
      `:carried_fee_applied` / `:carried_fee_not_held` otherwise.
  """
  @spec check(command(), t()) :: decision()
  def check(:refund, %__MODULE__{status: "refunded"}), do: :already_done

  def check(:refund, %__MODULE__{status: status} = fee) do
    cond do
      status not in CarriedFee.live_statuses() -> {:error, :no_carried_fee}
      not refundable?(fee) -> {:error, :fee_not_refundable}
      status == "applied" -> {:error, :carried_fee_applied}
      not fee.linked -> {:error, :payment_not_linked}
      true -> :ok
    end
  end

  def check(:link_payment, %__MODULE__{} = fee) do
    cond do
      fee.status not in CarriedFee.live_statuses() -> {:error, :no_carried_fee}
      fee.origin == "deferral" -> {:error, :not_imported}
      fee.linked -> {:error, :already_linked}
      true -> :ok
    end
  end

  def check(follow_up, %__MODULE__{refund: refund})
      when follow_up in @follow_ups and refund in [nil, :not_failed],
      do: {:error, :refund_not_failed}

  def check(follow_up, %__MODULE__{refund: :followed_up}) when follow_up in @follow_ups,
    do: {:error, :refund_followed_up}

  def check(:forfeit, %__MODULE__{status: nil}), do: {:error, :not_a_carried_fee_refund}
  def check(follow_up, %__MODULE__{status: nil}) when follow_up in @follow_ups, do: :ok
  def check(follow_up, %__MODULE__{status: "held"}) when follow_up in @follow_ups, do: :ok

  def check(follow_up, %__MODULE__{status: "refunded"}) when follow_up in [:retry, :manual],
    do: :ok

  def check(follow_up, %__MODULE__{status: "applied"}) when follow_up in @follow_ups,
    do: {:error, :carried_fee_applied}

  def check(follow_up, %__MODULE__{}) when follow_up in @follow_ups,
    do: {:error, :carried_fee_not_held}

  @doc """
  What the Waitlist tab offers: the commands `check/2` allows now, except
  that while a refund of the fee awaits its follow-up the tab offers Retry,
  Record manual refund and Forfeit rather than a new refund.
  """
  @spec available(t()) :: [command()]
  def available(%__MODULE__{} = fee) do
    @commands
    |> Enum.filter(&(check(&1, fee) == :ok))
    |> Enum.reject(&(&1 == :refund and fee.refund == :failed))
  end

  @doc """
  Whether a person may still have their Carried Fee refunded at `now` —
  while `waiting` (with or without a contacted Intake) or `removed` within
  the retention window (`Dhc.Waitlist.restorable?/2`); never once they
  attended (or later), nor once anonymised.
  """
  @spec fee_refundable?(String.t() | nil, DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def fee_refundable?("waiting", _removed_at, _now), do: true

  def fee_refundable?("removed", %DateTime{} = removed_at, %DateTime{} = now),
    do: Dhc.Waitlist.restorable?(removed_at, now)

  def fee_refundable?(_standing, _removed_at, _now), do: false

  defp refundable?(%__MODULE__{standing: standing, removed_at: removed_at, now: now}),
    do: fee_refundable?(standing, removed_at, now)
end
