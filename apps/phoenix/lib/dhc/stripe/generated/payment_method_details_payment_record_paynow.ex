defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordPaynow do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordPaynow
  """

  @type t :: %__MODULE__{
          location: String.t() | nil,
          reader: String.t() | nil,
          reference: String.t() | nil
        }

  defstruct [:location, :reader, :reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [location: :string, reader: :string, reference: :string]
  end
end
