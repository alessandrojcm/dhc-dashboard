defmodule Dhc.Stripe.PaymentMethodDetailsPix do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPix
  """

  @type t :: %__MODULE__{
          bank_transaction_id: String.t() | nil,
          fingerprint: String.t() | nil,
          mandate: String.t() | nil
        }

  defstruct [:bank_transaction_id, :fingerprint, :mandate]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bank_transaction_id: :string, fingerprint: :string, mandate: :string]
  end
end
