defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordPayto do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordPayto
  """

  @type t :: %__MODULE__{
          bsb_number: String.t() | nil,
          last4: String.t() | nil,
          mandate: String.t() | nil,
          pay_id: String.t() | nil
        }

  defstruct [:bsb_number, :last4, :mandate, :pay_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bsb_number: :string, last4: :string, mandate: :string, pay_id: :string]
  end
end
