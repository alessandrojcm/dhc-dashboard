defmodule Dhc.Stripe.PaymentMethodDetailsNzBankAccount do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsNzBankAccount
  """

  @type t :: %__MODULE__{
          account_holder_name: String.t() | nil,
          bank_code: String.t(),
          bank_name: String.t(),
          branch_code: String.t(),
          expected_debit_date: String.t() | nil,
          last4: String.t(),
          suffix: String.t() | nil
        }

  defstruct [
    :account_holder_name,
    :bank_code,
    :bank_name,
    :branch_code,
    :expected_debit_date,
    :last4,
    :suffix
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_name: :string,
      bank_code: :string,
      bank_name: :string,
      branch_code: :string,
      expected_debit_date: :string,
      last4: :string,
      suffix: :string
    ]
  end
end
