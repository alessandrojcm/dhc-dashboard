defmodule Dhc.Stripe.Item do
  @moduledoc """
  Provides struct and type for a Item
  """

  @type t :: %__MODULE__{
          adjustable_quantity: Dhc.Stripe.LineItemsAdjustableQuantity.t() | nil,
          amount_discount: integer,
          amount_subtotal: integer,
          amount_tax: integer,
          amount_total: integer,
          currency: String.t(),
          description: String.t() | nil,
          discounts: [Dhc.Stripe.LineItemsDiscountAmount.t()] | nil,
          id: String.t(),
          metadata: map | nil,
          object: String.t(),
          price: Dhc.Stripe.Price.t() | nil,
          quantity: integer | nil,
          taxes: [Dhc.Stripe.LineItemsTaxAmount.t()] | nil
        }

  defstruct [
    :adjustable_quantity,
    :amount_discount,
    :amount_subtotal,
    :amount_tax,
    :amount_total,
    :currency,
    :description,
    :discounts,
    :id,
    :metadata,
    :object,
    :price,
    :quantity,
    :taxes
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      adjustable_quantity: {Dhc.Stripe.LineItemsAdjustableQuantity, :t},
      amount_discount: :integer,
      amount_subtotal: :integer,
      amount_tax: :integer,
      amount_total: :integer,
      currency: {:string, "currency"},
      description: :string,
      discounts: [{Dhc.Stripe.LineItemsDiscountAmount, :t}],
      id: :string,
      metadata: :map,
      object: {:const, "item"},
      price: {Dhc.Stripe.Price, :t},
      quantity: :integer,
      taxes: [{Dhc.Stripe.LineItemsTaxAmount, :t}]
    ]
  end
end
