defmodule Dhc.Stripe.PaymentMethodOptionsCustomerBalance do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsCustomerBalance
  """

  @type t :: %__MODULE__{
          bank_transfer: Dhc.Stripe.PaymentMethodOptionsCustomerBalanceBankTransfer.t() | nil,
          funding_type: String.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [:bank_transfer, :funding_type, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_transfer: {Dhc.Stripe.PaymentMethodOptionsCustomerBalanceBankTransfer, :t},
      funding_type: {:const, "bank_transfer"},
      setup_future_usage: {:const, "none"}
    ]
  end
end
