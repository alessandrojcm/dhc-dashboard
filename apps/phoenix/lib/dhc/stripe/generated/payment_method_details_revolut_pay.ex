defmodule Dhc.Stripe.PaymentMethodDetailsRevolutPay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsRevolutPay
  """

  @type t :: %__MODULE__{
          funding: Dhc.Stripe.RevolutPayUnderlyingPaymentMethodFundingDetails.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:funding, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      funding: {Dhc.Stripe.RevolutPayUnderlyingPaymentMethodFundingDetails, :t},
      transaction_id: :string
    ]
  end
end
