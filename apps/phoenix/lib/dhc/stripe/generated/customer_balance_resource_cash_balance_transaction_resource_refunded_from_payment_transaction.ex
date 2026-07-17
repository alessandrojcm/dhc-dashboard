defmodule Dhc.Stripe.CustomerBalanceResourceCashBalanceTransactionResourceRefundedFromPaymentTransaction do
  @moduledoc """
  Provides struct and type for a CustomerBalanceResourceCashBalanceTransactionResourceRefundedFromPaymentTransaction
  """

  @type t :: %__MODULE__{refund: Dhc.Stripe.Refund.t() | String.t()}

  defstruct [:refund]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [refund: {:union, [:string, {Dhc.Stripe.Refund, :t}]}]
  end
end
