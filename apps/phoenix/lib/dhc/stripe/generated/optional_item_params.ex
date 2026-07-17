defmodule Dhc.Stripe.OptionalItemParams do
  @moduledoc """
  Provides struct and type for a OptionalItemParams
  """

  @type t :: %__MODULE__{
          adjustable_quantity: Dhc.Stripe.OptionalItemAdjustableQuantityParams.t() | nil,
          price: String.t(),
          quantity: integer
        }

  defstruct [:adjustable_quantity, :price, :quantity]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      adjustable_quantity: {Dhc.Stripe.OptionalItemAdjustableQuantityParams, :t},
      price: :string,
      quantity: :integer
    ]
  end
end
