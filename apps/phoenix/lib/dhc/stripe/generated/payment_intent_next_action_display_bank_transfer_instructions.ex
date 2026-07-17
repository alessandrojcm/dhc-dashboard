defmodule Dhc.Stripe.PaymentIntentNextActionDisplayBankTransferInstructions do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionDisplayBankTransferInstructions
  """

  @type t :: %__MODULE__{
          amount_remaining: integer | nil,
          currency: String.t() | nil,
          financial_addresses:
            [Dhc.Stripe.FundingInstructionsBankTransferFinancialAddress.t()] | nil,
          hosted_instructions_url: String.t() | nil,
          reference: String.t() | nil,
          type: String.t()
        }

  defstruct [
    :amount_remaining,
    :currency,
    :financial_addresses,
    :hosted_instructions_url,
    :reference,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_remaining: :integer,
      currency: {:string, "currency"},
      financial_addresses: [{Dhc.Stripe.FundingInstructionsBankTransferFinancialAddress, :t}],
      hosted_instructions_url: :string,
      reference: :string,
      type:
        {:enum,
         [
           "eu_bank_transfer",
           "gb_bank_transfer",
           "jp_bank_transfer",
           "mx_bank_transfer",
           "us_bank_transfer"
         ]}
    ]
  end
end
