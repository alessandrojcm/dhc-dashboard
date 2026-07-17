defmodule Dhc.Stripe.PortalFlowsFlowSubscriptionUpdateConfirm do
  @moduledoc """
  Provides struct and type for a PortalFlowsFlowSubscriptionUpdateConfirm
  """

  @type t :: %__MODULE__{
          discounts: [Dhc.Stripe.PortalFlowsSubscriptionUpdateConfirmDiscount.t()] | nil,
          items: [Dhc.Stripe.PortalFlowsSubscriptionUpdateConfirmItem.t()],
          subscription: String.t()
        }

  defstruct [:discounts, :items, :subscription]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      discounts: [{Dhc.Stripe.PortalFlowsSubscriptionUpdateConfirmDiscount, :t}],
      items: [{Dhc.Stripe.PortalFlowsSubscriptionUpdateConfirmItem, :t}],
      subscription: :string
    ]
  end
end
