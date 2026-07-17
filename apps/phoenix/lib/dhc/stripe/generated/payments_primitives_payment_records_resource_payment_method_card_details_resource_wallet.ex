defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceWallet do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceWallet
  """

  @type t :: %__MODULE__{
          apple_pay:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceWalletResourceApplePay.t()
            | nil,
          dynamic_last4: String.t() | nil,
          google_pay: map | nil,
          type: String.t()
        }

  defstruct [:apple_pay, :dynamic_last4, :google_pay, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      apple_pay:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceWalletResourceApplePay,
         :t},
      dynamic_last4: :string,
      google_pay: :map,
      type: :string
    ]
  end
end
