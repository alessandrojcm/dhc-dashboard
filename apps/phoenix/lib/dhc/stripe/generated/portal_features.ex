defmodule Dhc.Stripe.PortalFeatures do
  @moduledoc """
  Provides struct and type for a PortalFeatures
  """

  @type t :: %__MODULE__{
          customer_update: Dhc.Stripe.PortalCustomerUpdate.t(),
          invoice_history: Dhc.Stripe.PortalInvoiceList.t(),
          payment_method_update: Dhc.Stripe.PortalPaymentMethodUpdate.t(),
          subscription_cancel: Dhc.Stripe.PortalSubscriptionCancel.t(),
          subscription_update: Dhc.Stripe.PortalSubscriptionUpdate.t()
        }

  defstruct [
    :customer_update,
    :invoice_history,
    :payment_method_update,
    :subscription_cancel,
    :subscription_update
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      customer_update: {Dhc.Stripe.PortalCustomerUpdate, :t},
      invoice_history: {Dhc.Stripe.PortalInvoiceList, :t},
      payment_method_update: {Dhc.Stripe.PortalPaymentMethodUpdate, :t},
      subscription_cancel: {Dhc.Stripe.PortalSubscriptionCancel, :t},
      subscription_update: {Dhc.Stripe.PortalSubscriptionUpdate, :t}
    ]
  end
end
