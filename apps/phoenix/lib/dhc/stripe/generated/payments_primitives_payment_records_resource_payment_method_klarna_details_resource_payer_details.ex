defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodKlarnaDetailsResourcePayerDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodKlarnaDetailsResourcePayerDetails
  """

  @type t :: %__MODULE__{
          address:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodKlarnaDetailsResourcePayerDetailsResourcePayerDetailsAddress.t()
            | nil
        }

  defstruct [:address]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodKlarnaDetailsResourcePayerDetailsResourcePayerDetailsAddress,
         :t}
    ]
  end
end
