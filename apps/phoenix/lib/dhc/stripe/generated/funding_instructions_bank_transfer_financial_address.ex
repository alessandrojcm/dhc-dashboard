defmodule Dhc.Stripe.FundingInstructionsBankTransferFinancialAddress do
  @moduledoc """
  Provides struct and type for a FundingInstructionsBankTransferFinancialAddress
  """

  @type t :: %__MODULE__{
          aba: Dhc.Stripe.FundingInstructionsBankTransferAbaRecord.t() | nil,
          iban: Dhc.Stripe.FundingInstructionsBankTransferIbanRecord.t() | nil,
          sort_code: Dhc.Stripe.FundingInstructionsBankTransferSortCodeRecord.t() | nil,
          spei: Dhc.Stripe.FundingInstructionsBankTransferSpeiRecord.t() | nil,
          supported_networks: [String.t()] | nil,
          swift: Dhc.Stripe.FundingInstructionsBankTransferSwiftRecord.t() | nil,
          type: String.t(),
          zengin: Dhc.Stripe.FundingInstructionsBankTransferZenginRecord.t() | nil
        }

  defstruct [:aba, :iban, :sort_code, :spei, :supported_networks, :swift, :type, :zengin]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      aba: {Dhc.Stripe.FundingInstructionsBankTransferAbaRecord, :t},
      iban: {Dhc.Stripe.FundingInstructionsBankTransferIbanRecord, :t},
      sort_code: {Dhc.Stripe.FundingInstructionsBankTransferSortCodeRecord, :t},
      spei: {Dhc.Stripe.FundingInstructionsBankTransferSpeiRecord, :t},
      supported_networks: [
        enum: [
          "ach",
          "bacs",
          "chaps",
          "domestic_wire_us",
          "fps",
          "sepa",
          "spei",
          "swift",
          "zengin"
        ]
      ],
      swift: {Dhc.Stripe.FundingInstructionsBankTransferSwiftRecord, :t},
      type: {:enum, ["aba", "iban", "sort_code", "spei", "swift", "zengin"]},
      zengin: {Dhc.Stripe.FundingInstructionsBankTransferZenginRecord, :t}
    ]
  end
end
