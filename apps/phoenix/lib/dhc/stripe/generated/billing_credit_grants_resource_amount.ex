defmodule Dhc.Stripe.BillingCreditGrantsResourceAmount do
  @moduledoc """
  Provides struct and type for a BillingCreditGrantsResourceAmount
  """

  @type t :: %__MODULE__{
          monetary: Dhc.Stripe.BillingCreditGrantsResourceMonetaryAmount.t() | nil,
          type: String.t()
        }

  defstruct [:monetary, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      monetary: {Dhc.Stripe.BillingCreditGrantsResourceMonetaryAmount, :t},
      type: {:const, "monetary"}
    ]
  end
end
