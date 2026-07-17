defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordPix do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordPix
  """

  @type t :: %__MODULE__{bank_transaction_id: String.t() | nil, mandate: String.t() | nil}

  defstruct [:bank_transaction_id, :mandate]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bank_transaction_id: :string, mandate: :string]
  end
end
