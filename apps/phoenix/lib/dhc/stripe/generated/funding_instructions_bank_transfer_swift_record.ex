defmodule Dhc.Stripe.FundingInstructionsBankTransferSwiftRecord do
  @moduledoc """
  Provides struct and type for a FundingInstructionsBankTransferSwiftRecord
  """

  @type t :: %__MODULE__{
          account_holder_address: Dhc.Stripe.Address.t(),
          account_holder_name: String.t(),
          account_number: String.t(),
          account_type: String.t(),
          bank_address: Dhc.Stripe.Address.t(),
          bank_name: String.t(),
          swift_code: String.t()
        }

  defstruct [
    :account_holder_address,
    :account_holder_name,
    :account_number,
    :account_type,
    :bank_address,
    :bank_name,
    :swift_code
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
      bank_name: :string,
      swift_code: :string
    ]
  end
end
