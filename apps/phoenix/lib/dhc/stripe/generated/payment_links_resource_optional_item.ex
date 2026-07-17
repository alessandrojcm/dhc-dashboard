defmodule Dhc.Stripe.PaymentLinksResourceOptionalItem do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceOptionalItem
  """

  @type t :: %__MODULE__{
          adjustable_quantity:
            Dhc.Stripe.PaymentLinksResourceOptionalItemAdjustableQuantity.t() | nil,
          price: String.t(),
          quantity: integer
        }

  defstruct [:adjustable_quantity, :price, :quantity]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      adjustable_quantity: {Dhc.Stripe.PaymentLinksResourceOptionalItemAdjustableQuantity, :t},
      price: :string,
      quantity: :integer
    ]
  end
end
