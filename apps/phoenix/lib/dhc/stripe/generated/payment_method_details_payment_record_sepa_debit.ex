defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordSepaDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordSepaDebit
  """

  @type t :: %__MODULE__{
          bank_code: String.t() | nil,
          branch_code: String.t() | nil,
          country: String.t() | nil,
          expected_debit_date: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          mandate: String.t() | nil
        }

  defstruct [
    :bank_code,
    :branch_code,
    :country,
    :expected_debit_date,
    :fingerprint,
    :last4,
    :mandate
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_code: :string,
      branch_code: :string,
      country: :string,
      expected_debit_date: :string,
      fingerprint: :string,
      last4: :string,
      mandate: :string
    ]
  end
end
