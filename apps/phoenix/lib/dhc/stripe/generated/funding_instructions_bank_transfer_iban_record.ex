defmodule Dhc.Stripe.FundingInstructionsBankTransferIbanRecord do
  @moduledoc """
  Provides struct and type for a FundingInstructionsBankTransferIbanRecord
  """

  @type t :: %__MODULE__{
          account_holder_address: Dhc.Stripe.Address.t(),
          account_holder_name: String.t(),
          bank_address: Dhc.Stripe.Address.t(),
          bic: String.t(),
          country: String.t(),
          iban: String.t()
        }

  defstruct [:account_holder_address, :account_holder_name, :bank_address, :bic, :country, :iban]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_address: {Dhc.Stripe.Address, :t},
      account_holder_name: :string,
      bank_address: {Dhc.Stripe.Address, :t},
      bic: :string,
      country: :string,
      iban: :string
    ]
  end
end
