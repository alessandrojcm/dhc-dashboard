defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordAmazonPay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordAmazonPay
  """

  @type t :: %__MODULE__{
          funding:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAmazonPayDetailsResourceFunding.t()
            | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:funding, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      funding:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAmazonPayDetailsResourceFunding,
         :t},
      transaction_id: :string
    ]
  end
end
