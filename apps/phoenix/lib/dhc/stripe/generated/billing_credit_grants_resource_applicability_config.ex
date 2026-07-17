defmodule Dhc.Stripe.BillingCreditGrantsResourceApplicabilityConfig do
  @moduledoc """
  Provides struct and type for a BillingCreditGrantsResourceApplicabilityConfig
  """

  @type t :: %__MODULE__{scope: Dhc.Stripe.BillingCreditGrantsResourceScope.t()}

  defstruct [:scope]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [scope: {Dhc.Stripe.BillingCreditGrantsResourceScope, :t}]
  end
end
