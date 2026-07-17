defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourceAmount do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourceAmount
  """

  @type t :: %__MODULE__{currency: String.t(), value: integer}

  defstruct [:currency, :value]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [currency: {:string, "currency"}, value: :integer]
  end
end
