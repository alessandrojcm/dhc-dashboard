defmodule Dhc.Stripe.FundingInstructionsBankTransferSortCodeRecord do
  @moduledoc """
  Provides struct and type for a FundingInstructionsBankTransferSortCodeRecord
  """

  @type t :: %__MODULE__{
          account_holder_address: Dhc.Stripe.Address.t(),
          account_holder_name: String.t(),
          account_number: String.t(),
          bank_address: Dhc.Stripe.Address.t(),
          sort_code: String.t()
        }

  defstruct [
    :account_holder_address,
    :account_holder_name,
    :account_number,
    :bank_address,
    :sort_code
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_address: {Dhc.Stripe.Address, :t},
      account_holder_name: :string,
      account_number: :string,
      bank_address: {Dhc.Stripe.Address, :t},
      sort_code: :string
    ]
  end
end
