defmodule Dhc.Stripe.BillingCreditGrantsResourceBalanceCredit do
  @moduledoc """
  Provides struct and type for a BillingCreditGrantsResourceBalanceCredit
  """

  @type t :: %__MODULE__{
          amount: Dhc.Stripe.BillingCreditGrantsResourceAmount.t(),
          credits_application_invoice_voided:
            Dhc.Stripe.BillingCreditGrantsResourceBalanceCreditsApplicationInvoiceVoided.t() | nil,
          type: String.t()
        }

  defstruct [:amount, :credits_application_invoice_voided, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: {Dhc.Stripe.BillingCreditGrantsResourceAmount, :t},
      credits_application_invoice_voided:
        {Dhc.Stripe.BillingCreditGrantsResourceBalanceCreditsApplicationInvoiceVoided, :t},
      type: {:enum, ["credits_application_invoice_voided", "credits_granted"]}
    ]
  end
end
