defmodule Dhc.Stripe.PaymentMethodDetailsAuBecsDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsAuBecsDebit
  """

  @type t :: %__MODULE__{
          bsb_number: String.t() | nil,
          expected_debit_date: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          mandate: String.t() | nil
        }

  defstruct [:bsb_number, :expected_debit_date, :fingerprint, :last4, :mandate]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bsb_number: :string,
      expected_debit_date: :string,
      fingerprint: :string,
      last4: :string,
      mandate: :string
    ]
  end
end
