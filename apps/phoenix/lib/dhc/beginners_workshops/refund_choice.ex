defmodule Dhc.BeginnersWorkshops.RefundChoice do
  @moduledoc """
  The money a refund-or-forfeit choice settles (ALE-387/389), as the console
  roster and the Waitlist tab's person read show it (ALE-417). Pure: the
  callers say whether the choice is needed and hand over the money.

  The payment that paid a Stripe-paid Intake, else the Carried Fee (the one
  that paid the Intake, or the person's live one), each with the full
  amount it originally took.
  """

  @type money :: %{amount_cents: non_neg_integer() | nil, currency: String.t() | nil}
  @type t :: %{
          source: :payment | :carried_fee,
          amount_cents: non_neg_integer() | nil,
          currency: String.t() | nil
        }

  @doc """
  `nil` unless `required?`; otherwise the money: `paying` (the payment that
  paid a Stripe-paid Intake, or `nil` when it cannot be found) for a `paid`
  Intake with `paid_via: "stripe"`, else `fee` (`nil`: no amount known).
  """
  @spec of(
          boolean(),
          %{state: String.t() | nil, paid_via: String.t() | nil},
          money() | nil,
          money() | nil
        ) :: t() | nil
  def of(false, _intake, _paying, _fee), do: nil

  def of(true, %{state: "paid", paid_via: "stripe"}, paying, _fee),
    do: money(:payment, paying)

  def of(true, _intake, _paying, fee), do: money(:carried_fee, fee)

  defp money(source, nil), do: %{source: source, amount_cents: nil, currency: nil}

  defp money(source, money),
    do: %{source: source, amount_cents: money.amount_cents, currency: money.currency}
end
