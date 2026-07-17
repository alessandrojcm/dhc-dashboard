defmodule Dhc.Stripe.InvoiceSettingSubscriptionSchedulePhaseSetting do
  @moduledoc """
  Provides struct and type for a InvoiceSettingSubscriptionSchedulePhaseSetting
  """

  @type t :: %__MODULE__{
          account_tax_ids:
            [Dhc.Stripe.DeletedTaxId.t() | Dhc.Stripe.TaxId.t() | String.t()] | nil,
          days_until_due: integer | nil,
          issuer: Dhc.Stripe.ConnectAccountReference.t() | nil
        }

  defstruct [:account_tax_ids, :days_until_due, :issuer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_tax_ids: [union: [:string, {Dhc.Stripe.DeletedTaxId, :t}, {Dhc.Stripe.TaxId, :t}]],
      days_until_due: :integer,
      issuer: {Dhc.Stripe.ConnectAccountReference, :t}
    ]
  end
end
