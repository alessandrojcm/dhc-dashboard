defmodule Dhc.Stripe.SubscriptionsResourceSubscriptionInvoiceSettings do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceSubscriptionInvoiceSettings
  """

  @type t :: %__MODULE__{
          account_tax_ids:
            [Dhc.Stripe.DeletedTaxId.t() | Dhc.Stripe.TaxId.t() | String.t()] | nil,
          custom_fields: [Dhc.Stripe.InvoiceSettingCustomField.t()] | nil,
          description: String.t() | nil,
          footer: String.t() | nil,
          issuer: Dhc.Stripe.ConnectAccountReference.t()
        }

  defstruct [:account_tax_ids, :custom_fields, :description, :footer, :issuer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_tax_ids: [union: [:string, {Dhc.Stripe.DeletedTaxId, :t}, {Dhc.Stripe.TaxId, :t}]],
      custom_fields: [{Dhc.Stripe.InvoiceSettingCustomField, :t}],
      description: :string,
      footer: :string,
      issuer: {Dhc.Stripe.ConnectAccountReference, :t}
    ]
  end
end
