defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceShippingDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourceShippingDetails
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAddress.t(),
          name: String.t() | nil,
          phone: String.t() | nil
        }

  defstruct [:address, :name, :phone]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAddress, :t},
      name: :string,
      phone: :string
    ]
  end
end
