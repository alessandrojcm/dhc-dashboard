defmodule Dhc.Stripe.InvoicePaymentMethodOptionsParam do
  @moduledoc """
  Provides struct and types for a InvoicePaymentMethodOptionsParam
  """

  @type t :: %__MODULE__{
          bank_transfer: Dhc.Stripe.BankTransferParam.t() | nil,
          financial_connections: Dhc.Stripe.InvoiceLinkedAccountOptionsParam.t() | nil,
          funding_type: String.t() | nil,
          mandate_options:
            Dhc.Stripe.InvoicePaymentMethodOptionsMandateOptionsParam.t()
            | Dhc.Stripe.MandateOptionsParam.t()
            | nil,
          preferred_language: String.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [
    :bank_transfer,
    :financial_connections,
    :funding_type,
    :mandate_options,
    :preferred_language,
    :verification_method
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_transfer: {Dhc.Stripe.BankTransferParam, :t},
      financial_connections: {Dhc.Stripe.InvoiceLinkedAccountOptionsParam, :t},
      funding_type: :string,
      mandate_options:
        {:union,
         [
           {Dhc.Stripe.InvoicePaymentMethodOptionsMandateOptionsParam, :t},
           {Dhc.Stripe.MandateOptionsParam, :t}
         ]},
      preferred_language: {:enum, ["de", "en", "fr", "nl"]},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
