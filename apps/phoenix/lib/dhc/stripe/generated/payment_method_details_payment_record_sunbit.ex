defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordSunbit do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordSunbit
  """

  @type t :: %__MODULE__{transaction_id: String.t() | nil}

  defstruct [:transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [transaction_id: :string]
  end
end
