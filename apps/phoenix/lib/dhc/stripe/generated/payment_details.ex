defmodule Dhc.Stripe.PaymentDetails do
  @moduledoc """
  Provides struct and types for a PaymentDetails
  """

  @type t :: %__MODULE__{customer_reference: String.t() | nil, order_reference: String.t() | nil}

  defstruct [:customer_reference, :order_reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      customer_reference: {:union, [:string, const: ""]},
      order_reference: {:union, [:string, const: ""]}
    ]
  end
end
