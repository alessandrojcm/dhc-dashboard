defmodule Dhc.Stripe.FundingInstructionsBankTransferZenginRecord do
  @moduledoc """
  Provides struct and type for a FundingInstructionsBankTransferZenginRecord
  """

  @type t :: %__MODULE__{
          account_holder_address: Dhc.Stripe.Address.t(),
          account_holder_name: String.t() | nil,
          account_number: String.t() | nil,
          account_type: String.t() | nil,
          bank_address: Dhc.Stripe.Address.t(),
          bank_code: String.t() | nil,
          bank_name: String.t() | nil,
          branch_code: String.t() | nil,
          branch_name: String.t() | nil
        }

  defstruct [
    :account_holder_address,
    :account_holder_name,
    :account_number,
    :account_type,
    :bank_address,
    :bank_code,
    :bank_name,
    :branch_code,
    :branch_name
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_address: {Dhc.Stripe.Address, :t},
      account_holder_name: :string,
      account_number: :string,
      account_type: :string,
      bank_address: {Dhc.Stripe.Address, :t},
      bank_code: :string,
      bank_name: :string,
      branch_code: :string,
      branch_name: :string
    ]
  end
end
