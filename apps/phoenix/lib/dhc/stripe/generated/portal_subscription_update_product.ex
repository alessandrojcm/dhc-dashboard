defmodule Dhc.Stripe.PortalSubscriptionUpdateProduct do
  @moduledoc """
  Provides struct and type for a PortalSubscriptionUpdateProduct
  """

  @type t :: %__MODULE__{
          adjustable_quantity: Dhc.Stripe.PortalSubscriptionUpdateProductAdjustableQuantity.t(),
          prices: [String.t()],
          product: String.t()
        }

  defstruct [:adjustable_quantity, :prices, :product]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      adjustable_quantity: {Dhc.Stripe.PortalSubscriptionUpdateProductAdjustableQuantity, :t},
      prices: [:string],
      product: :string
    ]
  end
end
