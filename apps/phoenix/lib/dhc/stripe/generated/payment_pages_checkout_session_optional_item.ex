defmodule Dhc.Stripe.PaymentPagesCheckoutSessionOptionalItem do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionOptionalItem
  """

  @type t :: %__MODULE__{
          adjustable_quantity:
            Dhc.Stripe.PaymentPagesCheckoutSessionOptionalItemAdjustableQuantity.t() | nil,
          price: String.t(),
          quantity: integer
        }

  defstruct [:adjustable_quantity, :price, :quantity]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      adjustable_quantity:
        {Dhc.Stripe.PaymentPagesCheckoutSessionOptionalItemAdjustableQuantity, :t},
      price: :string,
      quantity: :integer
    ]
  end
end
