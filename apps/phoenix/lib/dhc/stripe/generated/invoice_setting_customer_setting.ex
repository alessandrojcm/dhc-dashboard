defmodule Dhc.Stripe.InvoiceSettingCustomerSetting do
  @moduledoc """
  Provides struct and type for a InvoiceSettingCustomerSetting
  """

  @type t :: %__MODULE__{
          custom_fields: [Dhc.Stripe.InvoiceSettingCustomField.t()] | nil,
          default_payment_method: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          footer: String.t() | nil,
          rendering_options: Dhc.Stripe.InvoiceSettingCustomerRenderingOptions.t() | nil
        }

  defstruct [:custom_fields, :default_payment_method, :footer, :rendering_options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      custom_fields: [{Dhc.Stripe.InvoiceSettingCustomField, :t}],
      default_payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      footer: :string,
      rendering_options: {Dhc.Stripe.InvoiceSettingCustomerRenderingOptions, :t}
    ]
  end
end
