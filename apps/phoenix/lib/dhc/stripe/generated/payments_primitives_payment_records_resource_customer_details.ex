defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceCustomerDetails do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourceCustomerDetails
  """

  @type t :: %__MODULE__{
          customer: String.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          phone: String.t() | nil
        }

  defstruct [:customer, :email, :name, :phone]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [customer: :string, email: :string, name: :string, phone: :string]
  end
end
