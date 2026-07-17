defmodule Dhc.Stripe.PaymentMethodDetailsAchCreditTransfer do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsAchCreditTransfer
  """

  @type t :: %__MODULE__{
          account_number: String.t() | nil,
          bank_name: String.t() | nil,
          routing_number: String.t() | nil,
          swift_code: String.t() | nil
        }

  defstruct [:account_number, :bank_name, :routing_number, :swift_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [account_number: :string, bank_name: :string, routing_number: :string, swift_code: :string]
  end
end
