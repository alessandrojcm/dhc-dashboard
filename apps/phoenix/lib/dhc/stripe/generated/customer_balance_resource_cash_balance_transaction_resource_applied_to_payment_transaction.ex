defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceAppliedToPaymentTransaction do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceAppliedToPaymentTransaction
  """

  @type t :: %__MODULE__{payment_intent: Dhc.Stripe.PaymentIntent.t() | String.t()}

  defstruct [:payment_intent]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [payment_intent: {:union, [:string, {Dhc.Stripe.PaymentIntent, :t}]}]
  end
end
