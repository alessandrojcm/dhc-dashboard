defmodule Dhc.Stripe.BankTransferParam do
  @moduledoc """
  Provides struct and types for a BankTransferParam
  """

  @type t :: %__MODULE__{
          eu_bank_transfer:
            Dhc.Stripe.EuBankTransferParam.t() | Dhc.Stripe.EuBankTransferParams.t() | nil,
          requested_address_types: [String.t()] | nil,
          type: String.t() | nil
        }

  defstruct [:eu_bank_transfer, :requested_address_types, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      eu_bank_transfer:
        {:union, [{Dhc.Stripe.EuBankTransferParam, :t}, {Dhc.Stripe.EuBankTransferParams, :t}]},
      requested_address_types: [
        enum: ["aba", "iban", "sepa", "sort_code", "spei", "swift", "zengin"]
      ],
      type:
        {:union,
         [
           :string,
           enum: [
             "eu_bank_transfer",
             "gb_bank_transfer",
             "jp_bank_transfer",
             "mx_bank_transfer",
             "us_bank_transfer"
           ]
         ]}
    ]
  end
end
