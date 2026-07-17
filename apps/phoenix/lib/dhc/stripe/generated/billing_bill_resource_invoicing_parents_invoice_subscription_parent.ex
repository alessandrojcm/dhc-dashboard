defmodule Dhc.Stripe.BillingBillResourceInvoicingParentsInvoiceSubscriptionParent do
  @moduledoc """
  Provides struct and type for a BillingBillResourceInvoicingParentsInvoiceSubscriptionParent
  """

  @type t :: %__MODULE__{
          metadata: map | nil,
          subscription: Dhc.Stripe.Subscription.t() | String.t(),
          subscription_proration_date: integer | nil
        }

  defstruct [:metadata, :subscription, :subscription_proration_date]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      metadata: :map,
      subscription: {:union, [:string, {Dhc.Stripe.Subscription, :t}]},
      subscription_proration_date: {:integer, "unix-time"}
    ]
  end
end
