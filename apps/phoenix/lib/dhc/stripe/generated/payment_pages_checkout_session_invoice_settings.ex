defmodule Dhc.Stripe.PaymentPagesCheckoutSessionInvoiceSettings do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionInvoiceSettings
  """

  @type t :: %__MODULE__{
          account_tax_ids:
            [Dhc.Stripe.DeletedTaxId.t() | Dhc.Stripe.TaxId.t() | String.t()] | nil,
          custom_fields: [Dhc.Stripe.InvoiceSettingCustomField.t()] | nil,
          description: String.t() | nil,
          footer: String.t() | nil,
          issuer: Dhc.Stripe.ConnectAccountReference.t() | nil,
          metadata: map | nil,
          rendering_options: Dhc.Stripe.InvoiceSettingCheckoutRenderingOptions.t() | nil
        }

  defstruct [
    :account_tax_ids,
    :custom_fields,
    :description,
    :footer,
    :issuer,
    :metadata,
    :rendering_options
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_tax_ids: [union: [:string, {Dhc.Stripe.DeletedTaxId, :t}, {Dhc.Stripe.TaxId, :t}]],
      custom_fields: [{Dhc.Stripe.InvoiceSettingCustomField, :t}],
      description: :string,
      footer: :string,
      issuer: {Dhc.Stripe.ConnectAccountReference, :t},
      metadata: :map,
      rendering_options: {Dhc.Stripe.InvoiceSettingCheckoutRenderingOptions, :t}
    ]
  end
end
