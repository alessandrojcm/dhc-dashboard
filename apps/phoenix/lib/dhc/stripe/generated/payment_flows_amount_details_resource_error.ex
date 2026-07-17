defmodule Dhc.Stripe.PaymentFlowsAmountDetailsResourceError do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetailsResourceError
  """

  @type t :: %__MODULE__{code: String.t() | nil, message: String.t() | nil}

  defstruct [:code, :message]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      code:
        {:enum,
         [
           "amount_details_amount_mismatch",
           "amount_details_tax_shipping_discount_greater_than_amount"
         ]},
      message: :string
    ]
  end
end
