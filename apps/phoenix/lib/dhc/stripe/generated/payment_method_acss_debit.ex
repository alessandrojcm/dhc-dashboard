defmodule Dhc.Stripe.PaymentMethodAcssDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodAcssDebit
  """

  @type t :: %__MODULE__{
          bank_name: String.t() | nil,
          fingerprint: String.t() | nil,
          institution_number: String.t() | nil,
          last4: String.t() | nil,
          transit_number: String.t() | nil
        }

  defstruct [:bank_name, :fingerprint, :institution_number, :last4, :transit_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_name: :string,
      fingerprint: :string,
      institution_number: :string,
      last4: :string,
      transit_number: :string
    ]
  end
end
