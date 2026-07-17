defmodule Dhc.Stripe.PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourceTax do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetailsResourceLineItemsListResourceLineItemResourceTax
  """

  @type t :: %__MODULE__{total_tax_amount: integer}

  defstruct [:total_tax_amount]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [total_tax_amount: :integer]
  end
end
