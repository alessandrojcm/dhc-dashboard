defmodule Dhc.Stripe.FlowDataSubscriptionUpdateConfirmParam do
  @moduledoc """
  Provides struct and type for a FlowDataSubscriptionUpdateConfirmParam
  """

  @type t :: %__MODULE__{
          discounts: [Dhc.Stripe.SubscriptionUpdateConfirmDiscountParams.t()] | nil,
          items: [Dhc.Stripe.SubscriptionUpdateConfirmItemParams.t()],
          subscription: String.t()
        }

  defstruct [:discounts, :items, :subscription]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      discounts: [{Dhc.Stripe.SubscriptionUpdateConfirmDiscountParams, :t}],
      items: [{Dhc.Stripe.SubscriptionUpdateConfirmItemParams, :t}],
      subscription: :string
    ]
  end
end
