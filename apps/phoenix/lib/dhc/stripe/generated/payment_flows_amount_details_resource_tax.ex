defmodule Dhc.Stripe.PaymentFlowsAmountDetailsResourceTax do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetailsResourceTax
  """

  @type t :: %__MODULE__{total_tax_amount: integer | nil}

  defstruct [:total_tax_amount]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [total_tax_amount: :integer]
  end
end
