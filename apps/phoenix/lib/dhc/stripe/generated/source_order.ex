defmodule Dhc.Stripe.SourceOrder do
  @moduledoc """
  Provides struct and type for a SourceOrder
  """

  @type t :: %__MODULE__{
          amount: integer,
          currency: String.t(),
          email: String.t() | nil,
          items: [Dhc.Stripe.SourceOrderItem.t()] | nil,
          shipping: Dhc.Stripe.Shipping.t() | nil
        }

  defstruct [:amount, :currency, :email, :items, :shipping]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      currency: {:string, "currency"},
      email: :string,
      items: [{Dhc.Stripe.SourceOrderItem, :t}],
      shipping: {Dhc.Stripe.Shipping, :t}
    ]
  end
end
