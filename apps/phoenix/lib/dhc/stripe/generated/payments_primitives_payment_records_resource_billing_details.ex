defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceBillingDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourceBillingDetails
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAddress.t(),
          email: String.t() | nil,
          name: String.t() | nil,
          phone: String.t() | nil
        }

  defstruct [:address, :email, :name, :phone]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAddress, :t},
      email: :string,
      name: :string,
      phone: :string
    ]
  end
end
