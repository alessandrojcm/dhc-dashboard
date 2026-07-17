defmodule Dhc.Stripe.BillingCreditGrantsResourceScope do
  @moduledoc """
  Provides struct and type for a BillingCreditGrantsResourceScope
  """

  @type t :: %__MODULE__{
          price_type: String.t() | nil,
          prices: [Dhc.Stripe.BillingCreditGrantsResourceApplicablePrice.t()] | nil
        }

  defstruct [:price_type, :prices]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      price_type: {:const, "metered"},
      prices: [{Dhc.Stripe.BillingCreditGrantsResourceApplicablePrice, :t}]
    ]
  end
end
