defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordAcssDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordAcssDebit
  """

  @type t :: %__MODULE__{
          bank_name: String.t() | nil,
          expected_debit_date: String.t() | nil,
          fingerprint: String.t() | nil,
          institution_number: String.t() | nil,
          last4: String.t() | nil,
          mandate: String.t() | nil,
          transit_number: String.t() | nil
        }

  defstruct [
    :bank_name,
    :expected_debit_date,
    :fingerprint,
    :institution_number,
    :last4,
    :mandate,
    :transit_number
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_name: :string,
      expected_debit_date: :string,
      fingerprint: :string,
      institution_number: :string,
      last4: :string,
      mandate: :string,
      transit_number: :string
    ]
  end
end
