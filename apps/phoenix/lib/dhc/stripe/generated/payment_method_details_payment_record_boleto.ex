defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordBoleto do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordBoleto
  """

  @type t :: %__MODULE__{tax_id: String.t() | nil}

  defstruct [:tax_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tax_id: :string]
  end
end
