defmodule Dhc.Stripe.InvoicesPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a InvoicesPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          acss_debit: Dhc.Stripe.InvoicePaymentMethodOptionsAcssDebit.t() | nil,
          bancontact: Dhc.Stripe.InvoicePaymentMethodOptionsBancontact.t() | nil,
          card: Dhc.Stripe.InvoicePaymentMethodOptionsCard.t() | nil,
          customer_balance: Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalance.t() | nil,
          konbini: map | nil,
          payto: Dhc.Stripe.InvoicePaymentMethodOptionsPayto.t() | nil,
          pix: Dhc.Stripe.InvoicePaymentMethodOptionsPix.t() | nil,
          sepa_debit: map | nil,
          upi: Dhc.Stripe.InvoicePaymentMethodOptionsUpi.t() | nil,
          us_bank_account: Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccount.t() | nil
        }

  defstruct [
    :acss_debit,
    :bancontact,
    :card,
    :customer_balance,
    :konbini,
    :payto,
    :pix,
    :sepa_debit,
    :upi,
    :us_bank_account
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      acss_debit: {Dhc.Stripe.InvoicePaymentMethodOptionsAcssDebit, :t},
      bancontact: {Dhc.Stripe.InvoicePaymentMethodOptionsBancontact, :t},
      card: {Dhc.Stripe.InvoicePaymentMethodOptionsCard, :t},
      customer_balance: {Dhc.Stripe.InvoicePaymentMethodOptionsCustomerBalance, :t},
      konbini: :map,
      payto: {Dhc.Stripe.InvoicePaymentMethodOptionsPayto, :t},
      pix: {Dhc.Stripe.InvoicePaymentMethodOptionsPix, :t},
      sepa_debit: :map,
      upi: {Dhc.Stripe.InvoicePaymentMethodOptionsUpi, :t},
      us_bank_account: {Dhc.Stripe.InvoicePaymentMethodOptionsUsBankAccount, :t}
    ]
  end
end
