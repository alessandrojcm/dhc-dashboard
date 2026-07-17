defmodule Dhc.Stripe.FundingInstructionsBankTransferSpeiRecord do
  @moduledoc """
  Provides struct and type for a FundingInstructionsBankTransferSpeiRecord
  """

  @type t :: %__MODULE__{
          account_holder_address: Dhc.Stripe.Address.t(),
          account_holder_name: String.t(),
          bank_address: Dhc.Stripe.Address.t(),
          bank_code: String.t(),
          bank_name: String.t(),
          clabe: String.t()
        }

  defstruct [
    :account_holder_address,
    :account_holder_name,
    :bank_address,
    :bank_code,
    :bank_name,
    :clabe
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_address: {Dhc.Stripe.Address, :t},
      account_holder_name: :string,
      bank_address: {Dhc.Stripe.Address, :t},
      bank_code: :string,
      bank_name: :string,
      clabe: :string
    ]
  end
end
