defmodule Dhc.Stripe.BillingCreditGrantsResourceBalanceDebit do
  @moduledoc """
  Provides struct and type for a BillingCreditGrantsResourceBalanceDebit
  """

  @type t :: %__MODULE__{
          amount: Dhc.Stripe.BillingCreditGrantsResourceAmount.t(),
          credits_applied: Dhc.Stripe.BillingCreditGrantsResourceBalanceCreditsApplied.t() | nil,
          type: String.t()
        }

  defstruct [:amount, :credits_applied, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: {Dhc.Stripe.BillingCreditGrantsResourceAmount, :t},
      credits_applied: {Dhc.Stripe.BillingCreditGrantsResourceBalanceCreditsApplied, :t},
      type: {:enum, ["credits_applied", "credits_expired", "credits_voided"]}
    ]
  end
end
