defmodule Dhc.Stripe.CheckoutCustomerBalancePaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutCustomerBalancePaymentMethodOptions
  """

  @type t :: %__MODULE__{
          bank_transfer:
            Dhc.Stripe.CheckoutCustomerBalanceBankTransferPaymentMethodOptions.t() | nil,
          funding_type: String.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [:bank_transfer, :funding_type, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_transfer: {Dhc.Stripe.CheckoutCustomerBalanceBankTransferPaymentMethodOptions, :t},
      funding_type: {:const, "bank_transfer"},
      setup_future_usage: {:const, "none"}
    ]
  end
end
