defmodule Dhc.Stripe.PaymentMethodUsBankAccountBlocked do
  @moduledoc """
  Provides struct and type for a PaymentMethodUsBankAccountBlocked
  """

  @type t :: %__MODULE__{network_code: String.t() | nil, reason: String.t() | nil}

  defstruct [:network_code, :reason]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      network_code:
        {:enum,
         ["R02", "R03", "R04", "R05", "R07", "R08", "R10", "R11", "R16", "R20", "R29", "R31"]},
      reason:
        {:enum,
         [
           "bank_account_closed",
           "bank_account_frozen",
           "bank_account_invalid_details",
           "bank_account_restricted",
           "bank_account_unusable",
           "debit_not_authorized",
           "tokenized_account_number_deactivated"
         ]}
    ]
  end
end
